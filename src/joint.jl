type Joint{T<:Real}
    name::String
    frameBefore::CartesianFrame3D
    frameAfter::CartesianFrame3D
    jointType::JointType{T}

    Joint(name::String, jointType::JointType{T}) = new(name, CartesianFrame3D(string("before_", name)), CartesianFrame3D(string("after_", name)), jointType)
end

Joint{T<:Real}(name::String, jointType::JointType{T}) = Joint{T}(name, jointType)

show(io::IO, joint::Joint) = print(io, "Joint \"$(joint.name)\": $(joint.jointType)")
showcompact(io::IO, joint::Joint) = print(io, "$(joint.name)")

num_positions(itr) = reduce((val, joint) -> val + num_positions(joint), 0, itr)
num_velocities(itr) = reduce((val, joint) -> val + num_velocities(joint), 0, itr)

@inline function check_num_positions(joint::Joint, vec::AbstractVector)
    length(vec) == num_positions(joint) || error("wrong size")
    nothing
end

@inline function check_num_velocities(joint::Joint, vec::AbstractVector)
    length(vec) == num_velocities(joint) || error("wrong size")
    nothing
end


# 'RTTI'-style dispatch inspired by https://groups.google.com/d/msg/julia-users/ude2-MUiFLM/z-MuQ9nhAAAJ, hopefully a short-term solution.
# See https://github.com/tkoolen/RigidBodyDynamics.jl/issues/93.

num_positions{M}(joint::Joint{M})::Int64 = @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) num_positions(joint.jointType)
num_velocities{M}(joint::Joint{M})::Int64 = @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) num_velocities(joint.jointType)

function joint_transform{M, X}(joint::Joint{M}, q::AbstractVector{X})::Transform3D{promote_type(M, X)}
    @boundscheck check_num_positions(joint, q)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _joint_transform(joint.jointType, joint.frameAfter, joint.frameBefore, q)
end

function motion_subspace{M, X}(joint::Joint{M}, q::AbstractVector{X})::JointGeometricJacobian{promote_type(M, X)}
    @boundscheck check_num_positions(joint, q)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _motion_subspace(joint.jointType, joint.frameAfter, joint.frameBefore, q)
end

function bias_acceleration{M, X}(joint::Joint{M}, q::AbstractVector{X}, v::AbstractVector{X})::SpatialAcceleration{promote_type(M, X)}
    @boundscheck check_num_positions(joint, q)
    @boundscheck check_num_velocities(joint, v)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _bias_acceleration(joint.jointType, joint.frameAfter, joint.frameBefore, q, v)
end

function configuration_derivative_to_velocity!{M}(joint::Joint{M}, v::AbstractVector, q::AbstractVector, q̇::AbstractVector)::Void
    @boundscheck check_num_velocities(joint, v)
    @boundscheck check_num_positions(joint, q)
    @boundscheck check_num_positions(joint, q̇)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _configuration_derivative_to_velocity!(joint.jointType, v, q, q̇)
end

function velocity_to_configuration_derivative!{M}(joint::Joint{M}, q̇::AbstractVector, q::AbstractVector, v::AbstractVector)::Void
    @boundscheck check_num_positions(joint, q̇)
    @boundscheck check_num_positions(joint, q)
    @boundscheck check_num_velocities(joint, v)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _velocity_to_configuration_derivative!(joint.jointType, q̇, q, v)
end

function zero_configuration!{M}(joint::Joint{M}, q::AbstractVector)::Void
    @boundscheck check_num_positions(joint, q)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _zero_configuration!(joint.jointType, q)
end

function rand_configuration!{M}(joint::Joint{M}, q::AbstractVector)::Void
    @boundscheck check_num_positions(joint, q)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _rand_configuration!(joint.jointType, q)
end

function joint_twist{M, X}(joint::Joint{M}, q::AbstractVector{X}, v::AbstractVector{X})::Twist{promote_type(M, X)}
    @boundscheck check_num_positions(joint, q)
    @boundscheck check_num_velocities(joint, v)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _joint_twist(joint.jointType, joint.frameAfter, joint.frameBefore, q, v)
end

function joint_torque!{M}(joint::Joint{M}, τ::AbstractVector, q::AbstractVector, joint_wrench::Wrench)::Void
    @boundscheck check_num_velocities(joint, τ)
    @boundscheck check_num_positions(joint, q)
    @framecheck(joint_wrench.frame, joint.frameAfter)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _joint_torque!(joint.jointType, τ, q, joint_wrench)
end

# TODO: also add:
# joint_acceleration
# motion_subspace with a transform argument

function motion_subspace{M, C, X}(joint::Joint{M}, toDesiredFrame::Transform3D{C}, q::AbstractVector{X})::JointGeometricJacobian{C}
    @boundscheck check_num_positions(joint, q)
    @framecheck(toDesiredFrame.from, joint.frameAfter)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _motion_subspace(joint.jointType, joint.frameAfter, joint.frameBefore, toDesiredFrame, q)
end

function momentum_matrix{M, C, X}(joint::Joint{M}, crbInertia::SpatialInertia{C}, afterJointToInertia::Transform3D{C}, q::AbstractVector{X})::JointMomentumMatrix{C}
    @boundscheck check_num_positions(joint, q)
    @framecheck(afterJointToInertia.from, joint.frameAfter)
    @framecheck(afterJointToInertia.to, crbInertia.frame)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _momentum_matrix(joint.jointType, crbInertia, afterJointToInertia, q)
end

function local_coordinates!{M}(joint::Joint{M},
        ϕ::AbstractVector, ϕ̇::AbstractVector,
        q0::AbstractVector, q::AbstractVector, v::AbstractVector)
    @boundscheck check_num_velocities(joint, ϕ)
    @boundscheck check_num_velocities(joint, ϕ̇)
    @boundscheck check_num_positions(joint, q0)
    @boundscheck check_num_positions(joint, q)
    @boundscheck check_num_velocities(joint, v)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _local_coordinates!(joint.jointType, ϕ, ϕ̇, q0, q, v)
end

function global_coordinates!{M}(joint::Joint{M}, q::AbstractVector, q0::AbstractVector, ϕ::AbstractVector)
    @boundscheck check_num_positions(joint, q)
    @boundscheck check_num_positions(joint, q0)
    @boundscheck check_num_velocities(joint, ϕ)
    @rtti_dispatch (QuaternionFloating{M}, Revolute{M}, Prismatic{M}, Fixed{M}) _global_coordinates!(joint.jointType, q, q0, ϕ)
end
