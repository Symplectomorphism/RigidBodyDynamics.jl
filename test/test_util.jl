import RigidBodyDynamics: hat, rotation_vector_rate, colwise

@testset "util" begin
    @testset "rotation vector rate" begin
        for ϕ in (rand(SVector{3}), zeros(SVector{3})) # exponential coordinates (rotation vector)
            ω = rand(SVector{3}) # angular velocity in body frame
            R = RotMatrix(RodriguesVec(ϕ...))
            Ṙ = R * hat(ω)
            ϕ̇ = rotation_vector_rate(ϕ, ω)
            Θ = norm(ϕ)
            if Θ > eps(Θ)
                ϕ_autodiff = SVector{3}(create_autodiff(ϕ, ϕ̇))
                R_autodiff = RotMatrix(RodriguesVec(ϕ_autodiff...))
                Ṙ_from_autodiff = map(x -> ForwardDiff.partials(x)[1], R_autodiff)
                @test isapprox(Ṙ_from_autodiff, Ṙ)
            else
                @test isapprox(ϕ̇, ω) # limit case; hard to test using autodiff because of division by zero
            end
        end
    end

    @testset "colwise" begin
        v = @SVector [2, 4, 6]
        M = @SMatrix [1 2 3; 4 5 6; 7 8 9]
        T = eltype(v)
        vcross = @SMatrix [zero(T) -v[3] v[2];
                       v[3] zero(T) -v[1];
                      -v[2] v[1] zero(T)]
        @test vcross * M == colwise(cross, v, M)
        @test colwise(cross, M, v) == -colwise(cross, v, M)
        @test colwise(+, M, v) == broadcast(+, M, v)
        v2 = @SVector [1, 2, 3, 4]
        @test_throws DimensionMismatch colwise(+, M, v2)
    end

    @testset "fastview" begin
        x1 = rand(5)
        x2 = [BigFloat(rand()) for i = 1 : 5]
        for x in (x1, x2)
            for range in (i : j for i in 1 : length(x), j in 1 : length(x) if j >= i)
                @test view(x, range) == RigidBodyDynamics.fastview(x, range)
            end
        end
    end
end
