# TODO: put in separate module

abstract JointType{T<:Real}
eltype{T}(::Union{JointType{T}, Type{JointType{T}}}) = T

# Default implementations
flip_direction{T}(jt::JointType{T}) = deepcopy(jt)

function _local_coordinates!(jt::JointType,
        ϕ::AbstractVector, ϕ̇::AbstractVector,
        q0::AbstractVector, q::AbstractVector, v::AbstractVector)
    sub!(ϕ, q, q0)
    copy!(ϕ̇, v)
end

function _global_coordinates!(jt::JointType, q::AbstractVector, q0::AbstractVector, ϕ::AbstractVector)
    @simd for i = 1 : length(q)
        q[i] = q0[i] + ϕ[i]
    end
    nothing
end


#=
QuaternionFloating
=#
immutable QuaternionFloating{T} <: JointType{T}
end

show(io::IO, jt::QuaternionFloating) = print(io, "Quaternion floating joint")
rand{T}(::Type{QuaternionFloating{T}}) = QuaternionFloating{T}()

num_positions(::QuaternionFloating) = 7
num_velocities(::QuaternionFloating) = 6

@inline function rotation(jt::QuaternionFloating, q::AbstractVector)
    @inbounds quat = Quat(q[1], q[2], q[3], q[4])
    quat
end
@inline function rotation!(jt::QuaternionFloating, q::AbstractVector, rot::Rotation{3})
    quat = Quat(rot)
    @inbounds q[1] = quat.w
    @inbounds q[2] = quat.x
    @inbounds q[3] = quat.y
    @inbounds q[4] = quat.z
    nothing
end

@inline translation(jt::QuaternionFloating, q::AbstractVector) = begin @inbounds trans = SVector(q[5], q[6], q[7]); trans end
@inline translation!(jt::QuaternionFloating, q::AbstractVector, trans::AbstractVector) = @inbounds copy!(q, 5, trans, 1, 3)

@inline angular_velocity(jt::QuaternionFloating, v::AbstractVector) = begin @inbounds ω = SVector(v[1], v[2], v[3]); ω end
@inline angular_velocity!(jt::QuaternionFloating, v::AbstractVector, ω::AbstractVector) = @inbounds copy!(v, 1, ω, 1, 3)

@inline linear_velocity(jt::QuaternionFloating, v::AbstractVector) = begin @inbounds ν = SVector(v[4], v[5], v[6]); ν end
@inline linear_velocity!(jt::QuaternionFloating, v::AbstractVector, ν::AbstractVector) = @inbounds copy!(v, 4, ν, 1, 3)

function _joint_transform(
        jt::QuaternionFloating, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector)
    S = promote_type(eltype(jt), eltype(q))
    rot = convert(Quat{S}, rotation(jt, q))
    trans = convert(SVector{3, S}, translation(jt, q))
    Transform3D{S}(frameAfter, frameBefore, rot, trans)
end

function _motion_subspace{T<:Real, X<:Real}(
        jt::QuaternionFloating{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X})
    S = promote_type(T, X)
    angular = hcat(eye(SMatrix{3, 3, S}), zeros(SMatrix{3, 3, S}))
    linear = hcat(zeros(SMatrix{3, 3, S}), eye(SMatrix{3, 3, S}))
    JointGeometricJacobian(frameAfter, frameBefore, frameAfter, angular, linear)
end

function _bias_acceleration{T<:Real, X<:Real}(
        jt::QuaternionFloating{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X}, v::AbstractVector{X})
    S = promote_type(T, X)
    zero(SpatialAcceleration{S}, frameAfter, frameBefore, frameAfter)
end

function _configuration_derivative_to_velocity!(jt::QuaternionFloating, v::AbstractVector, q::AbstractVector, q̇::AbstractVector)
    quat = rotation(jt, q)
    @inbounds quatdot = SVector(q̇[1], q̇[2], q̇[3], q̇[4])
    ω = angular_velocity_in_body(quat, quatdot)
    posdot = translation(jt, q̇)
    linear = inv(quat) * posdot
    angular_velocity!(jt, v, ω)
    linear_velocity!(jt, v, linear)
    nothing
end

function _velocity_to_configuration_derivative!(jt::QuaternionFloating, q̇::AbstractVector, q::AbstractVector, v::AbstractVector)
    quat = rotation(jt, q)
    ω = angular_velocity(jt, v)
    linear = linear_velocity(jt, v)
    quatdot = quaternion_derivative(quat, ω)
    transdot = quat * linear
    @inbounds q̇[1] = quatdot[1]# TODO: should use something like rotation!
    @inbounds q̇[2] = quatdot[2]
    @inbounds q̇[3] = quatdot[3]
    @inbounds q̇[4] = quatdot[4]
    translation!(jt, q̇, transdot)
    nothing
end

function _zero_configuration!(jt::QuaternionFloating, q::AbstractVector)
    T = eltype(q)
    rotation!(jt, q, eye(Quat{T}))
    translation!(jt, q, zeros(SVector{3, T}))
    nothing
end

function _rand_configuration!(jt::QuaternionFloating, q::AbstractVector)
    T = eltype(q)
    rotation!(jt, q, rand(Quat{T}))
    translation!(jt, q, randn(SVector{3, T}))
    nothing
end

function _joint_twist{T<:Real, X<:Real}(
        jt::QuaternionFloating{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X}, v::AbstractVector{X})
    S = promote_type(T, X)
    angular = convert(SVector{3, S}, angular_velocity(jt, v))
    linear = convert(SVector{3, S}, linear_velocity(jt, v))
    Twist(frameAfter, frameBefore, frameAfter, angular, linear)
end

function _joint_torque!(jt::QuaternionFloating, τ::AbstractVector, q::AbstractVector, joint_wrench::Wrench)
    angular_velocity!(jt, τ, joint_wrench.angular)
    linear_velocity!(jt, τ, joint_wrench.linear)
    nothing
end

function _momentum_matrix(jt::QuaternionFloating, crbInertia::SpatialInertia, afterJointToInertia::Transform3D, q::AbstractVector)
    crbInertia * transform(_motion_subspace(jt, afterJointToInertia.from, CartesianFrame3D(), q), afterJointToInertia)
end

# uses exponential coordinates centered around q0
function _local_coordinates!(jt::QuaternionFloating,
        ϕ::AbstractVector, ϕ̇::AbstractVector,
        q0::AbstractVector, q::AbstractVector, v::AbstractVector)
    # anonymous helper frames
    frameBefore = CartesianFrame3D()
    frame0 = CartesianFrame3D()
    frameAfter = CartesianFrame3D()

    t0 = _joint_transform(jt, frame0, frameBefore, q0) # 0 to before
    t = _joint_transform(jt, frameAfter, frameBefore, q) # after to before
    relative_transform = inv(t0) * t # relative to q0
    twist = _joint_twist(jt, frameAfter, frame0, q, v) # (q_0 is assumed not to change)
    ξ, ξ̇ = log_with_time_derivative(relative_transform, twist)

    @inbounds copy!(ϕ, 1, ξ.angular, 1, 3)
    @inbounds copy!(ϕ, 4, ξ.linear, 1, 3)

    @inbounds copy!(ϕ̇, 1, ξ̇.angular, 1, 3)
    @inbounds copy!(ϕ̇, 4, ξ̇.linear, 1, 3)

    nothing
end

function _global_coordinates!(jt::QuaternionFloating, q::AbstractVector, q0::AbstractVector, ϕ::AbstractVector)
    # anonymous helper frames
    frameBefore = CartesianFrame3D()
    frame0 = CartesianFrame3D()
    frameAfter = CartesianFrame3D()

    t0 = _joint_transform(jt, frame0, frameBefore, q0)
    @inbounds ξrot = SVector(ϕ[1], ϕ[2], ϕ[3])
    @inbounds ξtrans = SVector(ϕ[4], ϕ[5], ϕ[6])
    ξ = Twist(frameAfter, frame0, frame0, ξrot, ξtrans)
    relative_transform = exp(ξ)
    t = t0 * relative_transform
    rotation!(jt, q, t.rot)
    translation!(jt, q, t.trans)
    nothing
end



#=
OneDegreeOfFreedomFixedAxis
=#
abstract OneDegreeOfFreedomFixedAxis{T<:Real} <: JointType{T}

num_positions(::OneDegreeOfFreedomFixedAxis) = 1
num_velocities(::OneDegreeOfFreedomFixedAxis) = 1

function _zero_configuration!(::OneDegreeOfFreedomFixedAxis, q::AbstractVector)
    fill!(q, zero(eltype(q)))
    nothing
end

function _rand_configuration!(::OneDegreeOfFreedomFixedAxis, q::AbstractVector)
    randn!(q)
    nothing
 end

function _bias_acceleration{T<:Real, X<:Real}(
        jt::OneDegreeOfFreedomFixedAxis{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X}, v::AbstractVector{X})
    zero(SpatialAcceleration{promote_type(T, X)}, frameAfter, frameBefore, frameAfter)
end

function _configuration_derivative_to_velocity!(::OneDegreeOfFreedomFixedAxis, v::AbstractVector, q::AbstractVector, q̇::AbstractVector)
    copy!(v, q̇)
    nothing
end

function _velocity_to_configuration_derivative!(::OneDegreeOfFreedomFixedAxis, q̇::AbstractVector, q::AbstractVector, v::AbstractVector)
    copy!(q̇, v)
    nothing
end


#=
Prismatic
=#
immutable Prismatic{T<:Real} <: OneDegreeOfFreedomFixedAxis{T}
    translation_axis::SVector{3, T}
end

show(io::IO, jt::Prismatic) = print(io, "Prismatic joint with axis $(jt.translation_axis)")
function rand{T}(::Type{Prismatic{T}})
    axis = rand(SVector{3, T})
    Prismatic(axis / norm(axis))
end

flip_direction(jt::Prismatic) = Prismatic(-jt.translation_axis)

function _joint_transform(
        jt::Prismatic, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector)
    @inbounds translation = q[1] * jt.translation_axis
    Transform3D(frameAfter, frameBefore, translation)
end

function _joint_twist(
        jt::Prismatic, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector, v::AbstractVector)
    @inbounds linear = jt.translation_axis * v[1]
    Twist(frameAfter, frameBefore, frameAfter, zeros(linear), linear)
end

function _motion_subspace(jt::Prismatic, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector)
    T = promote_type(eltype(typeof(jt)), eltype(typeof(q)))
    angular = zeros(SMatrix{3, 1, T})
    linear = SMatrix{3, 1, T}(jt.translation_axis)
    JointGeometricJacobian(frameAfter, frameBefore, frameAfter, angular, linear)
end

function _joint_torque!(jt::Prismatic, τ::AbstractVector, q::AbstractVector, joint_wrench::Wrench)
    @inbounds τ[1] = dot(joint_wrench.linear, jt.translation_axis)
    nothing
end

function _momentum_matrix(jt::Prismatic, crbInertia::SpatialInertia, afterJointToInertia::Transform3D, q::AbstractVector)
    motionSubspaceLinear = rotate(jt.translation_axis, afterJointToInertia.rot)
    c = crbInertia.crossPart
    m = crbInertia.mass
    T = promote_type(eltype(typeof(jt)), eltype(typeof(q)))
    angular = SMatrix{3, 1, T}(cross(c, motionSubspaceLinear))
    linear = SMatrix{3, 1, T}(m * motionSubspaceLinear)
    JointMomentumMatrix(crbInertia.frame, angular, linear)
end


#=
Revolute
=#
immutable Revolute{T<:Real} <: OneDegreeOfFreedomFixedAxis{T}
    rotation_axis::SVector{3, T}
end

show(io::IO, jt::Revolute) = print(io, "Revolute joint with axis $(jt.rotation_axis)")
function rand{T}(::Type{Revolute{T}})
    axis = rand(SVector{3, T})
    Revolute(axis / norm(axis))
end

flip_direction(jt::Revolute) = Revolute(-jt.rotation_axis)

function _joint_transform{T<:Real, X<:Real}(
        jt::Revolute{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X})
    S = promote_type(T, X)
    @inbounds θ = q[1]
    s, c = sin(θ), cos(θ)
    ωHat = hat(jt.rotation_axis)
    rot = RotMatrix(eye(SMatrix{3, 3, S}) + ωHat * s + ωHat^2 * (one(c) - c)) # Rodrigues' formula. TODO: notify Rotations maintainers
    Transform3D(frameAfter, frameBefore, rot)
end

function _joint_twist(
        jt::Revolute, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector, v::AbstractVector)
    @inbounds angular_velocity = jt.rotation_axis * v[1]
    Twist(frameAfter, frameBefore, frameAfter, angular_velocity, zeros(angular_velocity))
end

function _motion_subspace{T<:Real, X<:Real}(
        jt::Revolute{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X})
    S = promote_type(T, X)
    angular = SMatrix{3, 1, S}(jt.rotation_axis)
    linear = zeros(SMatrix{3, 1, S})
    JointGeometricJacobian(frameAfter, frameBefore, frameAfter, angular, linear)
end

function _joint_torque!(jt::Revolute, τ::AbstractVector, q::AbstractVector, joint_wrench::Wrench)
    @inbounds τ[1] = dot(joint_wrench.angular, jt.rotation_axis)
    nothing
end

function _momentum_matrix(jt::Revolute, crbInertia::SpatialInertia, afterJointToInertia::Transform3D, q::AbstractVector)
    T = promote_type(eltype(typeof(jt)), eltype(typeof(q)))
    motionSubspaceAngular = rotate(jt.rotation_axis, afterJointToInertia.rot)
    motionSubspaceLinear = cross(afterJointToInertia.trans, motionSubspaceAngular)
    J = crbInertia.moment
    c = crbInertia.crossPart
    m = crbInertia.mass
    angular, linear = mul_inertia(J, c, m, motionSubspaceAngular, motionSubspaceLinear)
    JointMomentumMatrix(crbInertia.frame, SMatrix{3, 1, T}(angular), SMatrix{3, 1, T}(linear))
end


#=
Fixed
=#
immutable Fixed{T<:Real} <: JointType{T}
end
show(io::IO, jt::Fixed) = print(io, "Fixed joint")
rand{T}(::Type{Fixed{T}}) = Fixed{T}()

num_positions(::Fixed) = 0
num_velocities(::Fixed) = 0

function _joint_transform{T<:Real, X<:Real}(
        jt::Fixed{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X})
    Transform3D(promote_type(T, X), frameAfter, frameBefore)
end

function _joint_twist{T<:Real, X<:Real}(
        jt::Fixed{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X}, v::AbstractVector{X})
    zero(Twist{promote_type(T, X)}, frameAfter, frameBefore, frameAfter)
end

function _motion_subspace{T<:Real, X<:Real}(
        jt::Fixed{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X})
    S = promote_type(T, X)
    JointGeometricJacobian(frameAfter, frameBefore, frameAfter, zeros(SMatrix{3, 0, S}), zeros(SMatrix{3, 0, S}))
end

_zero_configuration!(::Fixed, q::AbstractVector) = nothing
_rand_configuration!(::Fixed, q::AbstractVector) = nothing

function _bias_acceleration{T<:Real, X<:Real}(
        jt::Fixed{T}, frameAfter::CartesianFrame3D, frameBefore::CartesianFrame3D, q::AbstractVector{X}, v::AbstractVector{X})
    zero(SpatialAcceleration{promote_type(T, X)}, frameAfter, frameBefore, frameAfter)
end

_configuration_derivative_to_velocity!(::Fixed, v::AbstractVector, q::AbstractVector, q̇::AbstractVector) = nothing
_velocity_to_configuration_derivative!(::Fixed, q̇::AbstractVector, q::AbstractVector, v::AbstractVector) = nothing
_joint_torque!(jt::Fixed, τ::AbstractVector, q::AbstractVector, joint_wrench::Wrench) = nothing

function _momentum_matrix(jt::Fixed, crbInertia::SpatialInertia, afterJointToInertia::Transform3D, q::AbstractVector)
    T = promote_type(eltype(typeof(jt)), eltype(typeof(q)))
    JointMomentumMatrix(crbInertia.frame, zeros(SMatrix{3, 0, T}), zeros(SMatrix{3, 0, T}))
end
