"""
$(SIGNATURES)

Return the mass of a subtree of a `Mechanism`, rooted at `base` (including
the mass of `base`).
"""
function subtree_mass{T}(base::RigidBody{T}, mechanism::Mechanism{T})
    result = isroot(base, mechanism) ? zero(T) : spatial_inertia(base).mass
    for joint in joints_to_children(base, mechanism)
        result += subtree_mass(successor(joint, mechanism), mechanism)
    end
    result
end

"""
$(SIGNATURES)

Return the total mass of the `Mechanism`.
"""
mass(m::Mechanism) = subtree_mass(root_body(m), m)

"""
$(SIGNATURES)

Compute the center of mass of an iterable subset of a `Mechanism`'s bodies in
the given state. Ignores the root body of the mechanism.
"""
function center_of_mass(state::MechanismState, itr)
    T = cache_eltype(state)
    mechanism = state.mechanism
    frame = root_frame(mechanism)
    com = Point3D(frame, zeros(SVector{3, T}))
    mass = zero(T)
    for body in itr
        if !isroot(body, mechanism)
            inertia = spatial_inertia(body)
            if inertia.mass > 0
                bodycom = transform_to_root(state, body) * center_of_mass(inertia)
                com += inertia.mass * FreeVector3D(bodycom)
                mass += inertia.mass
            end
        end
    end
    com /= mass
    com
end

"""
$(SIGNATURES)

Compute the center of mass of the whole `Mechanism` in the given state.
"""
center_of_mass(state::MechanismState) = center_of_mass(state, bodies(state.mechanism))

function _set_jacobian_part!(out::GeometricJacobian, part::GeometricJacobian, nextbaseframe::CartesianFrame3D, startind::Int64)
    @framecheck part.frame out.frame
    @framecheck part.base nextbaseframe
    n = 3 * num_cols(part)
    copy!(out.angular, startind, part.angular, 1, n)
    copy!(out.linear, startind, part.linear, 1, n)
    startind += n
    nextbaseframe = part.body
    startind, nextbaseframe
end

const geometric_jacobian_doc = """Compute a geometric Jacobian (also known as a
basic, or spatial Jacobian) associated with the joints that form a path in the
`Mechanism`'s spanning tree, in the given state.

A geometric Jacobian maps the vector of velocities associated with the joint path
to the twist of the body succeeding the last joint in the path with respect to
the body preceding the first joint in the path.

See also [`path`](@ref), [`GeometricJacobian`](@ref), [`velocity(state, path)`](@ref),
[`Twist`](@ref).
"""

"""
$(SIGNATURES)

$geometric_jacobian_doc

`transformfun` is a callable that may be used to transform the individual motion
subspaces of each of the joints to the frame in which `out` is expressed.

$noalloc_doc
"""
function geometric_jacobian!(out::GeometricJacobian, state::MechanismState, path::TreePath, transformfun)
    @boundscheck num_velocities(path) == num_cols(out) || error("size mismatch")
    mechanism = state.mechanism
    nextbaseframe = out.base
    startind = 1
    lastjoint = last(path)
    for (joint, direction) in path
        S = transformfun(motion_subspace_in_world(state, joint))
        direction == :up && (S = -S)
        startind, nextbaseframe = _set_jacobian_part!(out, S, nextbaseframe, startind)
        joint == lastjoint && (@framecheck S.body out.body)
    end
    out
end

"""
$(SIGNATURES)

$geometric_jacobian_doc

`root_to_desired` is the transform from the `Mechanism`'s root frame to the frame
in which `out` is expressed.

$noalloc_doc
"""
function geometric_jacobian!(out::GeometricJacobian, state::MechanismState, path::TreePath, root_to_desired::Transform3D)
    geometric_jacobian!(out, state, path, S -> transform(S, root_to_desired))
end

"""
$(SIGNATURES)

$geometric_jacobian_doc

See [`geometric_jacobian!(out, state, path, root_to_desired)`](@ref). Uses `state`
to compute the transform from the `Mechanism`'s root frame to the frame in which
`out` is expressed.

$noalloc_doc
"""
function geometric_jacobian!(out::GeometricJacobian, state::MechanismState, path::TreePath)
    if out.frame == root_frame(state.mechanism)
        geometric_jacobian!(out, state, path, identity)
    else
        geometric_jacobian!(out, state, path, inv(transform_to_root(state, out.frame)))
    end
end

"""
$(SIGNATURES)

$geometric_jacobian_doc

The Jacobian is computed in the `Mechanism`'s root frame.

See [`geometric_jacobian!(out, state, path)`](@ref).
"""
function geometric_jacobian{X, M, C}(state::MechanismState{X, M, C}, path::TreePath{RigidBody{M}, Joint{M}})
    nv = num_velocities(path)
    angular = Matrix{C}(3, nv)
    linear = Matrix{C}(3, nv)
    bodyframe = default_frame(target(path))
    baseframe = default_frame(source(path))
    jac = GeometricJacobian(bodyframe, baseframe, root_frame(state.mechanism), angular, linear)
    geometric_jacobian!(jac, state, path, identity)
end

"""
$(SIGNATURES)

Compute the spatial acceleration of `body` with respect to `base` for
the given state and joint acceleration vector ``\\dot{v}``.
"""
function relative_acceleration(state::MechanismState, body::RigidBody, base::RigidBody, v̇::AbstractVector)
    # This is kind of a strange algorithm due to the availability of bias accelerations w.r.t. world
    # in MechanismState, while computation of the v̇-dependent terms follows the shortest path in the tree.
    # TODO: consider doing everything in body frame

    C = cache_eltype(state)
    mechanism = state.mechanism

    bodyframe = default_frame(body)
    baseframe = default_frame(base)
    rootframe = root_frame(mechanism)

    bodyaccel = zero(SpatialAcceleration{C}, bodyframe, bodyframe, rootframe)
    baseaccel = zero(SpatialAcceleration{C}, baseframe, baseframe, rootframe)

    bias = -bias_acceleration(state, base) + bias_acceleration(state, body)
    while body != base
        do_body = tree_index(body, mechanism) > tree_index(base, mechanism)

        joint = do_body ? joint_to_parent(body, mechanism) : joint_to_parent(base, mechanism)
        S = motion_subspace_in_world(state, joint)
        v̇joint = fastview(v̇, velocity_range(state, joint))
        jointaccel = SpatialAcceleration(S, v̇joint)

        if do_body
            bodyaccel = jointaccel + bodyaccel
            body = predecessor(joint, mechanism)
        else
            baseaccel = jointaccel + baseaccel
            base = predecessor(joint, mechanism)
        end
    end
    (-baseaccel + bodyaccel) + bias
end

"""
$(SIGNATURES)

Return the gravitational potential energy in the given state, computed as the
negation of the dot product of the gravitational force and the center
of mass expressed in the `Mechanism`'s root frame.
"""
function gravitational_potential_energy{X, M, C}(state::MechanismState{X, M, C})
    gravitationalforce = mass(state.mechanism) * state.mechanism.gravitationalAcceleration
    -dot(gravitationalforce, FreeVector3D(center_of_mass(state)))
 end

 function force_space_matrix_transpose_mul_jacobian!(out::Matrix, rowstart::Int64, colstart::Int64,
        mat::Union{MomentumMatrix, WrenchMatrix}, jac::GeometricJacobian, sign::Int64)
     @framecheck(jac.frame, mat.frame)
     n = num_cols(mat)
     m = num_cols(jac)
     @boundscheck (rowstart > 0 && rowstart + n - 1 <= size(out, 1)) || error("size mismatch")
     @boundscheck (colstart > 0 && colstart + m - 1 <= size(out, 2)) || error("size mismatch")

     # more efficient version of
     # view(out, rowstart : rowstart + n - 1, colstart : colstart + n - 1)[:] = mat.angular' * jac.angular + mat.linear' * jac.linear

     @inbounds begin
         for col = 1 : m
             outcol = colstart + col - 1
             for row = 1 : n
                 outrow = rowstart + row - 1
                 out[outrow, outcol] = zero(eltype(out))
                 for i = 1 : 3
                     out[outrow, outcol] += flipsign(mat.angular[i, row] * jac.angular[i, col], sign)
                     out[outrow, outcol] += flipsign(mat.linear[i, row] * jac.linear[i, col], sign)
                 end
             end
         end
     end
 end

const mass_matrix_doc = """Compute the joint-space mass matrix
(also known as the inertia matrix) of the `Mechanism` in the given state, i.e.,
the matrix ``M(q)`` in the unconstrained joint-space equations of motion
```math
M(q) \\dot{v} + c(q, v, w_\\text{ext}) = \\tau
```

This method implements the composite rigid body algorithm.
"""

"""
$(SIGNATURES)

$mass_matrix_doc

$noalloc_doc

The `out` argument must be an ``n_v \\times n_v`` lower triangular
`Symmetric` matrix, where ``n_v`` is the dimension of the `Mechanism`'s joint
velocity vector ``v``.
"""
function mass_matrix!{X, M, C}(out::Symmetric{C, Matrix{C}}, state::MechanismState{X, M, C})
    @boundscheck size(out, 1) == num_velocities(state) || error("mass matrix has wrong size")
    @boundscheck out.uplo == 'L' || error("expected a lower triangular symmetric matrix type as the mass matrix")
    fill!(out.data, zero(C))
    mechanism = state.mechanism

    for jointi in tree_joints(mechanism)
        # Hii
        irange = velocity_range(state, jointi)
        if length(irange) > 0
            bodyi = successor(jointi, mechanism)
            Si = motion_subspace_in_world(state, jointi)
            Ii = crb_inertia(state, bodyi)
            F = Ii * Si
            istart = first(irange)
            force_space_matrix_transpose_mul_jacobian!(out.data, istart, istart, F, Si, 1)

            # Hji, Hij
            body = predecessor(jointi, mechanism)
            while (!isroot(body, mechanism))
                jointj = joint_to_parent(body, mechanism)
                jrange = velocity_range(state, jointj)
                if length(jrange) > 0
                    Sj = motion_subspace_in_world(state, jointj)
                    jstart = first(jrange)
                    force_space_matrix_transpose_mul_jacobian!(out.data, istart, jstart, F, Sj, 1)
                end
                body = predecessor(jointj, mechanism)
            end
        end
    end
end

"""
$(SIGNATURES)

$mass_matrix_doc
"""
function mass_matrix{X, M, C}(state::MechanismState{X, M, C})
    nv = num_velocities(state)
    ret = Symmetric(Matrix{C}(nv, nv), :L)
    mass_matrix!(ret, state)
    ret
end

const momentum_matrix_doc = """Compute the momentum matrix ``A(q)`` of the
`Mechanism` in the given state.

The momentum matrix maps the `Mechanism`'s joint velocity vector ``v`` to
its total momentum.

See also [`MomentumMatrix`](@ref).
"""

const momentum_matrix!_doc = """$momentum_matrix_doc
The `out` argument must be a mutable `MomentumMatrix` with as many columns as
the dimension of the `Mechanism`'s joint velocity vector ``v``.
"""

"""
$(SIGNATURES)

$momentum_matrix!_doc

`transformfun` is a callable that may be used to transform the individual
momentum matrix blocks associated with each of the joints to the frame in which
`out` is expressed.

$noalloc_doc
"""
function momentum_matrix!(out::MomentumMatrix, state::MechanismState, transformfun)
    @boundscheck num_velocities(state) == num_cols(out) || error("size mismatch")
    pos = 1
    mechanism = state.mechanism
    for joint in tree_joints(mechanism)
        body = successor(joint, mechanism)
        part = transformfun(crb_inertia(state, body) * motion_subspace_in_world(state, joint))
        @framecheck out.frame part.frame
        n = 3 * num_cols(part)
        copy!(out.angular, pos, part.angular, 1, n)
        copy!(out.linear, pos, part.linear, 1, n)
        pos += n
    end
end

"""
$(SIGNATURES)

$momentum_matrix!_doc

`root_to_desired` is the transform from the `Mechanism`'s root frame to the frame
in which `out` is expressed.

$noalloc_doc
"""
function momentum_matrix!(out::MomentumMatrix, state::MechanismState, root_to_desired::Transform3D)
    momentum_matrix!(out, state, IJ -> transform(IJ, root_to_desired))
end

"""
$(SIGNATURES)

$momentum_matrix!_doc

See [`momentum_matrix!(out, state, root_to_desired)`](@ref). Uses `state`
to compute the transform from the `Mechanism`'s root frame to the frame in which
`out` is expressed.

$noalloc_doc
"""
function momentum_matrix!(out::MomentumMatrix, state::MechanismState)
    if out.frame == root_frame(state.mechanism)
        momentum_matrix!(out, state, identity)
    else
        momentum_matrix!(out, state, inv(transform_to_root(state, out.frame)))
    end
end

"""
$(SIGNATURES)

$momentum_matrix_doc

See [`momentum_matrix!(out, state)`](@ref).
"""
function momentum_matrix(state::MechanismState)
    ncols = num_velocities(state)
    T = cache_eltype(state)
    ret = MomentumMatrix(root_frame(state.mechanism), Matrix{T}(3, ncols), Matrix{T}(3, ncols))
    momentum_matrix!(ret, state, identity)
    ret
end

function bias_accelerations!{T, X, M}(out::AbstractVector{SpatialAcceleration{T}}, state::MechanismState{X, M})
    mechanism = state.mechanism
    gravitybias = convert(SpatialAcceleration{T}, -gravitational_spatial_acceleration(mechanism))
    for joint in tree_joints(mechanism)
        body = successor(joint, mechanism)
        out[vertex_index(body)] = gravitybias + bias_acceleration(state, body)
    end
    nothing
end

function spatial_accelerations!{T, X, M}(out::AbstractVector{SpatialAcceleration{T}},
        state::MechanismState{X, M}, v̇::StridedVector)
    mechanism = state.mechanism

    # TODO: consider merging back into one loop
    # unbiased joint accelerations + gravity
    root = root_body(mechanism)
    out[vertex_index(root)] = convert(SpatialAcceleration{T}, -gravitational_spatial_acceleration(mechanism))
    for joint in tree_joints(mechanism)
        body = successor(joint, mechanism)
        S = motion_subspace_in_world(state, joint)
        v̇joint = fastview(v̇, velocity_range(state, joint))
        jointaccel = SpatialAcceleration(S, v̇joint)
        out[vertex_index(body)] = out[vertex_index(predecessor(joint, mechanism))] + jointaccel
    end

    # add bias acceleration - gravity
    for joint in tree_joints(mechanism)
        body = successor(joint, mechanism)
        out[vertex_index(body)] += bias_acceleration(state, body)
    end
    nothing
end

function newton_euler!{T, X, M, W}(
        out::AbstractVector{Wrench{T}}, state::MechanismState{X, M},
        accelerations::AbstractVector{SpatialAcceleration{T}},
        externalwrenches::AbstractVector{Wrench{W}})
    mechanism = state.mechanism
    for joint in tree_joints(mechanism)
        body = successor(joint, mechanism)
        wrench = newton_euler(state, body, accelerations[vertex_index(body)])
        out[vertex_index(body)] = wrench - externalwrenches[vertex_index(body)]
    end
end


function joint_wrenches_and_torques!{T, X, M}(
        torquesout::StridedVector{T},
        net_wrenches_in_joint_wrenches_out::AbstractVector{Wrench{T}},
        state::MechanismState{X, M})
    # Note: pass in net wrenches as wrenches argument. wrenches argument is modified to be joint wrenches
    @boundscheck length(torquesout) == num_velocities(state) || error("length of torque vector is wrong")
    mechanism = state.mechanism
    joints = tree_joints(mechanism)
    for i = length(joints) : -1 : 1
        joint = joints[i]
        body = successor(joint, mechanism)
        parentbody = predecessor(joint, mechanism)
        jointwrench = net_wrenches_in_joint_wrenches_out[vertex_index(body)]
        if !isroot(parentbody, mechanism)
            # TODO: consider also doing this for the root:
            net_wrenches_in_joint_wrenches_out[vertex_index(parentbody)] += jointwrench # action = -reaction
        end
        jointwrench = transform(jointwrench, inv(transform_to_root(state, body))) # TODO: stay in world frame?
        @inbounds τjoint = fastview(torquesout, velocity_range(state, joint))
        joint_torque!(joint, τjoint, configuration(state, joint), jointwrench)
    end
end

"""
$(SIGNATURES)

Compute the 'dynamics bias term', i.e. the term
```math
c(q, v, w_\\text{ext})
```
in the unconstrained joint-space equations of motion
```math
M(q) \\dot{v} + c(q, v, w_\\text{ext}) = \\tau
```
given joint configuration vector ``q``, joint velocity vector ``v``,
joint acceleration vector ``\\dot{v}`` and (optionally) external
wrenches ``w_\\text{ext}``.

The `externalwrenches` argument can be used to specify additional
wrenches that act on the `Mechanism`'s bodies. `externalwrenches` should be a
vector for which `externalwrenches[vertex_index(body)]` is the wrench exerted
upon `body`.

$noalloc_doc
"""
function dynamics_bias!{T, X, M, W}(
        torques::AbstractVector{T},
        biasaccelerations::AbstractVector{SpatialAcceleration{T}},
        wrenches::AbstractVector{Wrench{T}},
        state::MechanismState{X, M},
        externalwrenches::AbstractVector{Wrench{W}} = ConstVector(zero(Wrench{T}, root_frame(state.mechanism)), num_bodies(state.mechanism)))
    bias_accelerations!(biasaccelerations, state)
    newton_euler!(wrenches, state, biasaccelerations, externalwrenches)
    joint_wrenches_and_torques!(torques, wrenches, state)
end

const inverse_dynamics_doc = """Do inverse dynamics, i.e. compute ``\\tau``
in the unconstrained joint-space equations of motion
```math
M(q) \\dot{v} + c(q, v, w_\\text{ext}) = \\tau
```
given joint configuration vector ``q``, joint velocity vector ``v``,
joint acceleration vector ``\\dot{v}`` and (optionally) external
wrenches ``w_\\text{ext}``.

The `externalwrenches` argument can be used to specify additional
wrenches that act on the `Mechanism`'s bodies. `externalwrenches` should be a
vector for which `externalwrenches[vertex_index(body)]` is the wrench exerted
upon `body`.

This method implements the recursive Newton-Euler algorithm.

Currently doesn't support `Mechanism`s with cycles.
"""

"""
$(SIGNATURES)

$inverse_dynamics_doc

$noalloc_doc
"""
function inverse_dynamics!{T, X, M, V, W}(
        torquesout::AbstractVector{T},
        jointwrenchesout::AbstractVector{Wrench{T}},
        accelerations::AbstractVector{SpatialAcceleration{T}},
        state::MechanismState{X, M},
        v̇::AbstractVector{V},
        externalwrenches::AbstractVector{Wrench{W}} = ConstVector(zero(Wrench{T}, root_frame(state.mechanism)), num_bodies(state.mechanism)))
    length(tree_joints(state.mechanism)) == length(joints(state.mechanism)) || error("This method can currently only handle tree Mechanisms.")
    spatial_accelerations!(accelerations, state, v̇)
    newton_euler!(jointwrenchesout, state, accelerations, externalwrenches)
    joint_wrenches_and_torques!(torquesout, jointwrenchesout, state)
end

"""
$(SIGNATURES)

$inverse_dynamics_doc
"""
function inverse_dynamics{X, M, V, W}(
        state::MechanismState{X, M},
        v̇::AbstractVector{V},
        externalwrenches::AbstractVector{Wrench{W}} = ConstVector(zero(Wrench{X}, root_frame(state.mechanism)), num_bodies(state.mechanism)))
    T = promote_type(X, M, V, W)
    torques = Vector{T}(num_velocities(state))
    nb = num_bodies(state.mechanism)
    jointwrenches = Vector{Wrench{T}}(nb)
    accelerations = Vector{SpatialAcceleration{T}}(nb)
    inverse_dynamics!(torques, jointwrenches, accelerations, state, v̇, externalwrenches)
    torques
end

function constraint_jacobian_and_bias!(state::MechanismState, constraintjacobian::AbstractMatrix, constraintbias::AbstractVector)
    # TODO: allocations
    mechanism = state.mechanism
    rowstart = 1
    constraintjacobian[:] = 0
    for (nontreejoint, path) in state.constraint_jacobian_structure
        nextrowstart = rowstart + num_constraints(nontreejoint)
        range = rowstart : nextrowstart - 1

        # Constraint wrench subspace.
        jointtransform = relative_transform(state, frame_after(nontreejoint), frame_before(nontreejoint)) # TODO: expensive
        T = constraint_wrench_subspace(nontreejoint, jointtransform)
        T = transform(T, transform_to_root(state, T.frame)) # TODO: expensive

        # Jacobian rows.
        for (treejoint, direction) in path
            J = motion_subspace_in_world(state, treejoint)
            colstart = first(velocity_range(state, treejoint))
            sign = ifelse(direction == :up, -1, 1)
            force_space_matrix_transpose_mul_jacobian!(constraintjacobian, rowstart, colstart, T, J, sign)
        end

        # Constraint bias.
        has_fixed_subspaces(nontreejoint) || error("Only joints with fixed motion subspace (Ṡ = 0) supported at this point.")
        kjoint = fastview(constraintbias, range)
        pred = predecessor(nontreejoint, mechanism)
        succ = successor(nontreejoint, mechanism)
        biasaccel = cross(twist_wrt_world(state, succ), twist_wrt_world(state, pred)) + (bias_acceleration(state, succ) + -bias_acceleration(state, pred)) # 8.47 in Featherstone
        At_mul_B!(kjoint, T, biasaccel)
        rowstart = nextrowstart
    end
end

function contact_dynamics!{X, M, C, T}(result::DynamicsResult{M, T}, state::MechanismState{X, M, C})
    mechanism = state.mechanism
    root = root_body(mechanism)
    frame = default_frame(root)
    for body in bodies(mechanism)
        wrench = zero(Wrench{T}, frame)
        points = contact_points(body)
        if !isempty(points)
            # TODO: AABB
            body_to_root = transform_to_root(state, body)
            twist = twist_wrt_world(state, body)
            states = contact_states(state, body)
            state_derivs = contact_state_derivatives(result, body)
            for i = 1 : length(points)
                @inbounds c = points[i]
                # TODO: AABB check here
                point = body_to_root * location(c)
                velocity = point_velocity(twist, point)
                for primitive in mechanism.environment.halfspaces
                    model = contact_model(c)
                    contact_state = states[i]
                    contact_state_deriv = state_derivs[i]
                    # TODO: would be good to move this to Contact module
                    # arguments: model, state, state_deriv, point, velocity, primitive
                    if point_inside(primitive, point)
                        separation, normal = Contact.detect_contact(primitive, point)
                        force = Contact.contact_dynamics!(contact_state_deriv, contact_state,
                            model, -separation, velocity, normal)
                        wrench += Wrench(point, force)
                    else
                        Contact.reset!(contact_state)
                        Contact.zero!(contact_state_deriv)
                    end
                end
            end
        end
        set_contact_wrench!(result, body, wrench)
    end
end

function dynamics_solve!(result::DynamicsResult, τ::AbstractVector)
    # version for general scalar types
    # TODO: make more efficient
    M = result.massmatrix
    c = result.dynamicsbias
    v̇ = result.v̇

    K = result.constraintjacobian
    k = result.constraintbias
    λ = result.λ

    nv = size(M, 1)
    nl = size(K, 1)
    G = [full(M) K'; # TODO: full because of https://github.com/JuliaLang/julia/issues/21332
         K zeros(nl, nl)]
    r = [τ - c; -k]
    v̇λ = G \ r
    v̇[:] = view(v̇λ, 1 : nv)
    λ[:] = view(v̇λ, nv + 1 : nv + nl)
    nothing
end

function dynamics_solve!{S<:Number, T<:LinAlg.BlasReal}(result::DynamicsResult{S, T}, τ::AbstractVector{T})
    # optimized version for BLAS floats
    M = result.massmatrix
    c = result.dynamicsbias
    v̇ = result.v̇

    K = result.constraintjacobian
    k = result.constraintbias
    λ = result.λ

    L = result.L
    A = result.A
    z = result.z
    Y = result.Y

    L[:] = M.data
    uplo = M.uplo
    LinAlg.LAPACK.potrf!(uplo, L) # L <- Cholesky decomposition of M; M == L Lᵀ (note: Featherstone, page 151 uses M == Lᵀ L instead)
    τBiased = v̇
    @simd for i in eachindex(τ)
        @inbounds τBiased[i] = τ[i] - c[i]
    end
    # TODO: use τBiased .= τ .- c in 0.6

    if size(K, 1) > 0
        # Loops.
        # Basic math:
        # DAE:
        #   [M Kᵀ] [v̇] = [τ - c]
        #   [K 0 ] [λ]  = [-k]
        # Solve for v̇:
        #   v̇ = M⁻¹ (τ - c - Kᵀ λ)
        # Plug into λ equation:
        #   K M⁻¹ (τ - c - Kᵀ λ) = -k
        #   K M⁻¹ Kᵀ λ = K M⁻¹(τ - c) + k
        # which can be solved for λ, after which λ can be used to solve for v̇.

        # Implementation loosely follows page 151 of Featherstone, Rigid Body Dynamics Algorithms.
        # It is slightly different because Featherstone uses M = Lᵀ L, whereas BLAS uses M = L Lᵀ.
        # M = L Lᵀ (Cholesky decomposition)
        # Y = K L⁻ᵀ, so that Y Yᵀ = K L⁻ᵀ L⁻¹ Kᵀ = K M⁻¹ Kᵀ = A
        # z = L⁻¹ (τ - c)
        # b = Y z + k
        # solve A λ = b for λ
        # solve M v̇  = τ - c for v̇

        # Compute Y = K L⁻ᵀ
        Y[:] = K
        LinAlg.BLAS.trsm!('R', uplo, 'T', 'N', one(T), L, Y)

        # Compute z = L⁻¹ (τ - c)
        z[:] = τBiased
        LinAlg.BLAS.trsv!(uplo, 'N', 'N', L, z) # z <- L⁻¹ (τ - c)

        # Compute A = Y Yᵀ == K * M⁻¹ * Kᵀ
        LinAlg.BLAS.gemm!('N', 'T', one(T), Y, Y, zero(T), A) # A <- K * M⁻¹ * Kᵀ

        # Compute b = Y z + k
        b = λ
        b[:] = k
        LinAlg.BLAS.gemv!('N', one(T), Y, z, one(T), b) # b <- Y z + k

        # Compute λ = A⁻¹ b == (K * M⁻¹ * Kᵀ)⁻¹ * (K * M⁻¹ * (τ - c) + k)
        LinAlg.LAPACK.posv!(uplo, A, b) # b == λ <- (K * M⁻¹ * Kᵀ)⁻¹ * (K * M⁻¹ * (τ - c) + k)

        # Update τBiased: subtract Kᵀ * λ
        LinAlg.BLAS.gemv!('T', -one(T), K, λ, one(T), τBiased) # τBiased <- τ - c - Kᵀ * λ

        # Solve for v̇ = M⁻¹ * (τ - c - Kᵀ * λ)
        LinAlg.LAPACK.potrs!(uplo, L, τBiased) # τBiased ==v̇ <- M⁻¹ * (τ - c - Kᵀ * λ)
    else
        # No loops.
        LinAlg.LAPACK.potrs!(uplo, L, τBiased) # τBiased == v̇ <- M⁻¹ * (τ - c)
    end
    nothing
end

"""
$(SIGNATURES)

Compute the joint acceleration vector ``\\dot{v}`` and Lagrange multipliers
``\\lambda`` that satisfy the joint-space equations of motion
```math
M(q) \\dot{v} + c(q, v, w_\\text{ext}) = \\tau - K(q)^{T} \\lambda
```
and the constraint equations
```math
K(q) \\dot{v} = -k
```
given joint configuration vector ``q``, joint velocity vector ``v``, and
(optionally) joint torques ``\\tau`` and external wrenches ``w_\\text{ext}``.

The `externalwrenches` argument can be used to specify additional
wrenches that act on the `Mechanism`'s bodies. `externalwrenches` should be a
vector for which `externalwrenches[vertex_index(body)]` is the wrench exerted
upon `body`.
"""
function dynamics!{T, X, M, Tau, W}(result::DynamicsResult{T}, state::MechanismState{X, M},
        torques::AbstractVector{Tau} = ConstVector(zero(T), num_velocities(state)),
        externalwrenches::AbstractVector{Wrench{W}} = ConstVector(zero(Wrench{T}, root_frame(state.mechanism)), num_bodies(state.mechanism)))
    contact_dynamics!(result, state)
    for i in eachindex(result.totalwrenches) # TODO: dot syntax on 0.6
        result.totalwrenches[i] = externalwrenches[i] + result.contactwrenches[i]
    end
    dynamics_bias!(result.dynamicsbias, result.accelerations, result.jointwrenches, state, result.totalwrenches)
    mass_matrix!(result.massmatrix, state)
    constraint_jacobian_and_bias!(state, result.constraintjacobian, result.constraintbias)
    dynamics_solve!(result, torques)
    nothing
end


"""
$(SIGNATURES)

Convenience function for use with standard ODE integrators that takes a
`Vector` argument
```math
x = \\left(\\begin{array}{c}
q\\\\
v
\\end{array}\\right)
```
and returns a `Vector` ``\\dot{x}``.
"""
function dynamics!{T, X, M, Tau, W}(ẋ::StridedVector{X},
        result::DynamicsResult{T}, state::MechanismState{X, M}, stateVec::AbstractVector{X},
        torques::AbstractVector{Tau} = ConstVector(zero(T), num_velocities(state)),
        externalwrenches::AbstractVector{Wrench{W}} = ConstVector(zero(Wrench{T}, root_frame(state.mechanism)), num_bodies(state.mechanism)))
    set!(state, stateVec)
    nq = num_positions(state)
    nv = num_velocities(state)
    q̇ = view(ẋ, 1 : nq) # allocates
    v̇ = view(ẋ, nq + 1 : nq + nv) # allocates
    configuration_derivative!(q̇, state)
    dynamics!(result, state, torques, externalwrenches)
    copy!(v̇, result.v̇)
    ẋ
end
