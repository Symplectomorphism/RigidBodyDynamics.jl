abstract JointType

immutable Joint
    name::ASCIIString
    frameBefore::CartesianFrame3D
    frameAfter::CartesianFrame3D
    jointType::JointType

    Joint(name::ASCIIString, jointType::JointType) = new(name, CartesianFrame3D(string("before_", name)), CartesianFrame3D(string("after_", name)), jointType)
end

immutable QuaternionFloating <: JointType
    motionSubspaceAngular::Array{Float64, 2}
    motionSubspaceLinear::Array{Float64, 2}
    function QuaternionFloating()
        motionSubspaceAngular = [eye(3) zeros(3, 3)]
        motionSubspaceLinear = [zeros(3, 3) eye(3)]
        new(motionSubspaceAngular, motionSubspaceLinear)
    end
end

function joint_transform{T}(j::Joint, q::Vector{T}, jt::QuaternionFloating = j.jointType)
    rot = Quaternion(q[1], q[2 : 4])
    trans = Vec(q[5 : 7])
    return Transform3D{T}(j.frameAfter, j.frameBefore, rot, trans)
end

function motion_subspace{T}(j::Joint, q::Vector{T}, jt::QuaternionFloating = j.jointType)
    return MotionSubspaceBasis(j.frameBefore, j.frameAfter, j.frameAfter, jt.motionSubspaceAngular, jt.motionSubspaceLinear)
end

num_positions(j::Joint, jt::QuaternionFloating = j.jointType) = 7

num_velocities(j::Joint, jt::QuaternionFloating = j.jointType) = 6

function zero_configuration{T}(j::Joint, ::Type{T}, jt::QuaternionFloating = j.jointType)
    return [one(T); zeros(T, 6)]
end
function rand_configuration{T}(j::Joint, ::Type{T}, jt::QuaternionFloating = j.jointType)
    quat = nquatrand()
    return [quat.s; quat.v1; quat.v2; quat.v3; rand(T, 3)]
end

function joint_twist{T}(j::Joint, q::Vector{T}, v::Vector{T}, jt::QuaternionFloating = j.jointType)
    return Twist(j.frameAfter, j.frameBefore, j.frameAfter, Vec(v[1 : 3]), Vec(v[4 : 6]))
end

immutable Prismatic{T} <: JointType
    translation_axis::Vec{3, T}
    motionSubspaceAngular::Vector{Float64}
    motionSubspaceLinear::Vector{Float64}
    Prismatic(translation_axis::Vec{3, T}) = new(translation_axis, zeros(3), Array(translation_axis))
end
Prismatic{T}(rotation_axis::Vec{3, T}) = Prismatic{T}(rotation_axis)

joint_transform{T1, T2}(j::Joint, q::Vector{T1}, jt::Prismatic{T2} = j.jointType) = Transform3D(j.frameAfter, j.frameBefore, q[1] * jt.translation_axis)

function joint_twist{T}(j::Joint, q::Vector{T}, v::Vector{T}, jt::Prismatic = j.jointType)
    return Twist(j.frameAfter, j.frameBefore, j.frameAfter, zero(Vec{3, T}), jt.translation_axis * v[1])
end

function motion_subspace{T}(j::Joint, q::Vector{T}, jt::Prismatic = j.jointType)
    return MotionSubspaceBasis(j.frameBefore, j.frameAfter, j.frameAfter, jt.motionSubspaceAngular, jt.motionSubspaceLinear)
end

immutable Revolute{T} <: JointType
    rotation_axis::Vec{3, T}
    motionSubspaceAngular::Vector{Float64}
    motionSubspaceLinear::Vector{Float64}
    Revolute(rotation_axis::Vec{3, T}) = new(rotation_axis, Array(rotation_axis), zeros(3))
end
Revolute{T}(rotation_axis::Vec{3, T}) = Revolute{T}(rotation_axis)

joint_transform{T1, T2}(j::Joint, q::Vector{T1}, jt::Revolute{T2} = j.jointType) = Transform3D(j.frameAfter, j.frameBefore, qrotation(Array(jt.rotation_axis), q[1]))

function joint_twist{T}(j::Joint, q::Vector{T}, v::Vector{T}, jt::Revolute = j.jointType)
    return Twist(j.frameAfter, j.frameBefore, j.frameAfter, jt.rotation_axis * v[1], zero(Vec{3, T}))
end

function motion_subspace{T}(j::Joint, q::Vector{T}, jt::Revolute = j.jointType)
    return MotionSubspaceBasis(j.frameBefore, j.frameAfter, j.frameAfter, jt.motionSubspaceAngular, jt.motionSubspaceLinear)
end

typealias OneDOF{T} Union{Prismatic{T}, Revolute{T}}
num_positions{T}(j::Joint, jt::OneDOF{T} = j.jointType) = 1
num_velocities{T}(j::Joint, jt::OneDOF{T} = j.jointType) = 1
function zero_configuration{T}(j::Joint, ::Type{T}, jt::OneDOF = j.jointType)
    return [0]
end
function rand_configuration{T}(j::Joint, ::Type{T}, jt::OneDOF = j.jointType)
    return [rand(T)]
end
