type LoopJoint{T}
    joint::Joint{T}
    predecessor::RigidBody{T}
    successor::RigidBody{T}
end

type Mechanism{T<:Real}
    toposortedTree::Vector{TreeVertex{RigidBody{T}, Joint{T}}} # TODO: consider replacing with just the root vertex after creating iterator
    loopJoints::Vector{LoopJoint{T}}
    gravitationalAcceleration::FreeVector3D{SVector{3, T}} # TODO: consider removing

    function Mechanism(rootBody::RigidBody{T}; gravity::SVector{3, T} = SVector(zero(T), zero(T), T(-9.81)))
        tree = Tree{RigidBody{T}, Joint{T}}(rootBody)
        loopJoints = Vector{LoopJoint{T}}()
        gravitationalAcceleration = FreeVector3D(default_frame(rootBody), gravity)
        new(toposort(tree), loopJoints, gravitationalAcceleration)
    end
end

Mechanism{T}(rootBody::RigidBody{T}; kwargs...) = Mechanism{T}(rootBody; kwargs...)
Mechanism{T}(m::Mechanism{T}) = Mechanism{T}(m)
eltype{T}(::Mechanism{T}) = T
root_vertex(m::Mechanism) = m.toposortedTree[1]
non_root_vertices(m::Mechanism) = view(m.toposortedTree, 2 : length(m.toposortedTree)) # TODO: allocates
tree(m::Mechanism) = m.toposortedTree[1]
root_body(m::Mechanism) = vertex_data(root_vertex(m))
root_frame(m::Mechanism) = default_frame(root_body(m))
path(m::Mechanism, from::RigidBody, to::RigidBody) = path(findfirst(tree(m), from), findfirst(tree(m), to))
show(io::IO, m::Mechanism) = print(io, m.toposortedTree[1])
isinertial(m::Mechanism, frame::CartesianFrame3D) = is_fixed_to_body(frame, root_body(m))
isroot{T}(m::Mechanism{T}, b::RigidBody{T}) = b == root_body(m)
joints(m::Mechanism) = (edge_to_parent_data(vertex) for vertex in non_root_vertices(m))
bodies{T}(m::Mechanism{T}) = (vertex_data(vertex) for vertex in m.toposortedTree)
non_root_bodies{T}(m::Mechanism{T}) = (vertex_data(vertex) for vertex in non_root_vertices(m))
num_positions(m::Mechanism) = num_positions(joints(m))
num_velocities(m::Mechanism) = num_velocities(joints(m))
num_bodies(m::Mechanism) = length(m.toposortedTree)

function body_fixed_frame_to_body(m::Mechanism, frame::CartesianFrame3D)
    # linear in number of bodies and number of frames; not meant to be super fast
    for vertex in m.toposortedTree
        body = vertex_data(vertex)
        if is_fixed_to_body(body, frame)
            return body
        end
    end
    error("Unable to determine to what body $(frame) is attached")
end

function body_fixed_frame_definition(m::Mechanism, frame::CartesianFrame3D)
    frame_definition(body_fixed_frame_to_body(m, frame), frame)
end

function fixed_transform(m::Mechanism, from::CartesianFrame3D, to::CartesianFrame3D)
    fixed_transform(body_fixed_frame_to_body(m, from), from, to)
end

Base.@deprecate add_body_fixed_frame!{T}(m::Mechanism{T}, body::RigidBody{T}, transform::Transform3D{T}) add_frame!(body, transform)

function add_body_fixed_frame!{T}(m::Mechanism{T}, transform::Transform3D{T})
    add_frame!(body_fixed_frame_to_body(m, transform.to), transform)
end

function canonicalize_frame_definitions!{T}(m::Mechanism{T}, vertex::TreeVertex{RigidBody{T}, Joint{T}})
    if !isroot(vertex)
        body = vertex_data(vertex)
        joint = edge_to_parent_data(vertex)
        parentBody = vertex_data(parent(vertex))
        newDefaultFrame = joint.frameAfter
        change_default_frame!(body, newDefaultFrame)
    end
end

function canonicalize_frame_definitions!(m::Mechanism)
    for vertex in non_root_vertices(m)
        canonicalize_frame_definitions!(m, vertex)
    end
end

function attach!{T}(m::Mechanism{T}, parentBody::RigidBody{T}, joint::Joint, jointToParent::Transform3D{T},
        childBody::RigidBody{T}, childToJoint::Transform3D{T} = Transform3D{T}(default_frame(childBody), joint.frameAfter))
    vertex = insert!(tree(m), childBody, joint, parentBody)

    # define where joint is attached on parent body
    add_frame!(parentBody, jointToParent)

    # define where child is attached to joint
    add_frame!(childBody, inv(childToJoint))

    m.toposortedTree = toposort(tree(m))
    canonicalize_frame_definitions!(m, vertex)
    m
end

# Essentially replaces the root body of childMechanism with parentBody (which belongs to m)
function attach!{T}(m::Mechanism{T}, parentBody::RigidBody{T}, childMechanism::Mechanism{T})
    # note: gravitational acceleration for childMechanism is ignored.
    parentVertex = findfirst(tree(m), parentBody)
    childRootVertex = root_vertex(childMechanism)
    childRootBody = vertex_data(childRootVertex)

    # define where child root body is located w.r.t parent body
    # and add frames that were attached to childRootBody to parentBody
    add_frame!(parentBody, Transform3D{T}(default_frame(childRootBody), default_frame(parentBody))) # TODO: add optional function argument
    for transform in frame_definitions(childRootBody)
        add_frame!(parentBody, transform)
    end
    canonicalize_frame_definitions!(m, parentVertex)

    # merge trees
    for child in children(childRootVertex)
        vertex = insert_subtree!(parentVertex, child)
        canonicalize_frame_definitions!(m, vertex)
    end

    m.toposortedTree = toposort(tree(m))

    m
end

function submechanism{T}(m::Mechanism{T}, submechanismRootBody::RigidBody{T})
    # Create mechanism and set up tree
    ret = Mechanism{T}(submechanismRootBody; gravity = m.gravitationalAcceleration.v)
    for child in children(findfirst(tree(m), submechanismRootBody))
        insert_subtree!(root_vertex(ret), child)
    end
    ret.toposortedTree = toposort(tree(ret))
    canonicalize_frame_definitions!(ret)
    ret
end

#=
Detaches the subtree rooted at oldSubtreeRootBody, reroots it so that newSubtreeRootBody is the new root, and then attaches
newSubtreeRootBody to parentBody using the specified joint.
=#
function reattach!{T}(mechanism::Mechanism{T}, oldSubtreeRootBody::RigidBody{T},
        parentBody::RigidBody{T}, joint::Joint, jointToParent::Transform3D{T},
        newSubtreeRootBody::RigidBody{T}, newSubTreeRootBodyToJoint::Transform3D{T} = Transform3D{T}(default_frame(newSubtreeRootBody), joint.frameAfter))
    # TODO: add option to prune frames related to old joints

    newSubtreeRoot = findfirst(tree(mechanism), newSubtreeRootBody)
    oldSubtreeRoot = findfirst(tree(mechanism), oldSubtreeRootBody)
    parentVertex = findfirst(tree(mechanism), parentBody)
    @assert newSubtreeRoot ∈ toposort(oldSubtreeRoot)
    @assert parentVertex ∉ toposort(oldSubtreeRoot)

    # detach oldSubtreeRoot
    detach!(oldSubtreeRoot)

    # reroot
    flippedJoints = Dict{Joint{T}, Joint{T}}()
    flipDirectionFunction = joint -> begin
        flipped = Joint(joint.name * "_flipped", flip_direction(joint.jointType))
        flippedJoints[joint] = flipped
        flipped
    end
    subtreeRerooted = reroot(newSubtreeRoot, flipDirectionFunction)

    # attach newSubtreeRoot using joint
    insert!(parentVertex, subtreeRerooted, joint)
    mechanism.toposortedTree = toposort(tree(mechanism))

    # define frames related to new joint
    add_frame!(parentBody, jointToParent)
    add_frame!(newSubtreeRootBody, inv(newSubTreeRootBodyToJoint))

    # define identities between new frames and old frames and recanonicalize frame definitions
    for (oldJoint, newJoint) in flippedJoints
        add_body_fixed_frame!(mechanism, Transform3D{T}(newJoint.frameBefore, oldJoint.frameAfter))
        add_body_fixed_frame!(mechanism, Transform3D{T}(newJoint.frameAfter, oldJoint.frameBefore))
    end
    canonicalize_frame_definitions!(mechanism)

    flippedJoints
end

function remove_fixed_joints!(m::Mechanism)
    T = eltype(m)
    for vertex in copy(m.toposortedTree)
        if !isroot(vertex)
            body = vertex_data(vertex)
            joint = edge_to_parent_data(vertex)
            parentVertex = parent(vertex)
            parentBody = vertex_data(parentVertex)
            if isa(joint.jointType, Fixed)
                # add identity joint transform as a body-fixed frame definition
                jointTransform = Transform3D{T}(joint.frameAfter, joint.frameBefore)
                add_frame!(parentBody, jointTransform)

                # migrate body fixed frames to parent body
                for tf in frame_definitions(body)
                    add_frame!(parentBody, tf)
                end

                # add inertia to parent body
                if has_defined_inertia(parentBody)
                    inertia = spatial_inertia(body)
                    parentInertia = spatial_inertia(parentBody)
                    toParent = fixed_transform(parentBody, inertia.frame, parentInertia.frame)
                    parentBody.inertia = parentInertia + transform(inertia, toParent)
                end

                # merge vertex into parent
                formerChildren = children(vertex)
                merge_into_parent!(vertex)

                # recanonicalize children since their new parent's default frame may be different
                for child in formerChildren
                    canonicalize_frame_definitions!(m, child)
                end
            end
        end
    end
    m.toposortedTree = toposort(tree(m))
    m
end

function rand_mechanism{T}(::Type{T}, parentSelector::Function, jointTypes...)
    parentBody = RigidBody{T}("world")
    m = Mechanism(parentBody)
    for i = 1 : length(jointTypes)
        @assert jointTypes[i] <: JointType{T}
        joint = Joint("joint$i", rand(jointTypes[i]))
        jointToParentBody = rand(Transform3D{T}, joint.frameBefore, default_frame(parentBody))
        body = RigidBody(rand(SpatialInertia{T}, CartesianFrame3D("body$i")))
        bodyToJoint = Transform3D{T}(default_frame(body), joint.frameAfter)
        attach!(m, parentBody, joint, jointToParentBody, body, bodyToJoint)
        parentBody = parentSelector(m)
    end
    return m
end

rand_chain_mechanism{T}(t::Type{T}, jointTypes...) = rand_mechanism(t, m::Mechanism -> vertex_data(m.toposortedTree[end]), jointTypes...)
rand_tree_mechanism{T}(t::Type{T}, jointTypes...) = rand_mechanism(t, m::Mechanism -> rand(collect(bodies(m))), jointTypes...)
function rand_floating_tree_mechanism{T}(t::Type{T}, nonFloatingJointTypes...)
    parentSelector = (m::Mechanism) -> begin
        only_root = length(bodies(m)) == 1
        only_root ? root_body(m) : rand(collect(non_root_bodies(m)))
    end
    rand_mechanism(t, parentSelector, [QuaternionFloating{T}; nonFloatingJointTypes...]...)
end

function gravitational_spatial_acceleration{M}(m::Mechanism{M})
    frame = m.gravitationalAcceleration.frame
    SpatialAcceleration(frame, frame, frame, zeros(SVector{3, M}), m.gravitationalAcceleration.v)
end

function subtree_mass{T}(base::Tree{RigidBody{T}, Joint{T}})
    result = isroot(base) ? zero(T) : spatial_inertia(vertex_data(base)).mass
    for child in children(base)
        result += subtree_mass(child)
    end
    result
end
mass(m::Mechanism) = subtree_mass(tree(m))
