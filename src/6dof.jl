using Solvers
using Parser
using Utils

using LinearAlgebra
using ECOS

using Symbolics

include("./Rocket_Acceleration.jl")
include("./Quaternions.jl")

using FiniteDifferences
using DifferentialEquations

using NPZ
using Plots

export solve, save, print, plot

function solve(algo)
    pbm = TrajectoryProblem(nothing)
    problem_set_dims!(pbm, 13, 4, 2)
    set_scale!(pbm)

    g = [0; 0; -9.80655];

    r_0 = [20; -4; 30];	# position vector, m
    v_0 = [4; -3; 0];		# velocity vector, m/s
    q_0 = [1; 0; 0; 0];
    w_0 = [0; 0; 0]

    r_N =[0; 0; 0];				# terminal position, m
    v_N =[0; 0; 0];				# terminal velocity, m
    q_N = [1; 0; 0; 0]; # or any roll of this.
    w_N = [0; 0; 0];

    # problem_set_guess!(
    #     pbm, (N, pbm) -> begin
    #         g = [0; 0; -9.80655];

    #         function rocket!(x_dot, x, p ,t)
    #             x_dot[1:3] = x[4:6]
    #             x_dot[4:6] = g + [0; 0; Acceleration(t)]
    #         end
            
    #         tspan = (0.0, 100.0) # should be long enough for rocket to hit ground
            
    #         r0 = [20.0; -4.0; 30.0]
    #         v0 = [4.0; -3.0; 0.0]
    #         t_coast = 0.0
    #         x0 = [r0 + v0 * t_coast + g * t_coast^2/2; v0 + g * t_coast];
    #         prob = ODEProblem(rocket!,x0,tspan) # prob = ODEProblem(rocket!,[20; -4; 30;4; -3; 0], tspan, u0)
            
    #         condition(x,t,integrator) = x[3] # when zero halt integration
    #         affect!(integrator) = terminate!(integrator)
    #         cb = ContinuousCallback(condition,affect!)
    #         sol = DifferentialEquations.solve(prob,Tsit5(),callback=cb)
            
    #         x = zeros(pbm.nx, N)
    #         u = zeros(pbm.nu, N)
            
    #         t_burn = sol.t[end]
    #         p = [t_coast; t_burn]

    #         for k = 1:N
    #             t = (k - 1) / (N - 1) * t_burn
    #             x[:, k] = sol(t)
    #             u[:, k] = [0; 0; Acceleration(t)]
    #         end
    #         return x, u, p 
    #     end
    # )

    problem_set_guess!(
        pbm, (N, pbm) -> begin
            t_coast = 0.0
            t_burn = 3.45

            x0 = [r_0 + v_0 * t_coast + g * t_coast^2/2; v_0 + g * t_coast; q_0; w_0];
            xf = [r_N; v_N; q_N; w_N]
            
            x = zeros(pbm.nx, N)
            u = zeros(pbm.nu, N)
            
            p = [t_coast; t_burn]

            for k = 1:N
                t = (k - 1) / (N - 1) * t_burn
                x[:, k] = (t_burn - t) / t_burn * x0 + t / t_burn * xf
                u[:, k] = [0; 0; Acceleration(t); 0]
            end

            return x, u, p 
        end
    )

    # Cost function
    # problem_set_running_cost!(
    #     pbm, :scvx, (t, k, x, u, p, pbm) -> #dot(x[4:6] - v_N, x[4:6] - v_N) # I don't think you can use norm, package needs to be updated or smth.
    #     #dot([zeros(3, 1); 2 * (x[4:6] - v_N)], f(x, u) * p[2]);
    #     #dot(x[4:6], g + u) * p[2]
    # )
    problem_set_terminal_cost!(
        pbm, (x, p, pbm) -> dot(x[4: 6] - v_N, x[4: 6] - v_N)
    )
    
    Id = Diagonal([0.2, 0.2, 0.04])

    @variables r[1:3] v[1:3] u[1:4] quat[1:4] w[1:3];
    r = Symbolics.scalarize(r);
    v = Symbolics.scalarize(v);
    quat = Symbolics.scalarize(quat);
    w = Symbolics.scalarize(w);
    u = Symbolics.scalarize(u);

    x = [r; v; quat; w];
    
    x_dot = [v; g + u[1:3]; 1/2 * quatL(quat) * [0; w]; inv(Id) * (cross([0; 0; -0.5], u[1:3]) + [0; 0; u[4]] - cross(w, Id * w))]
    A_sym = Symbolics.jacobian(x_dot, x)
    B_sym = Symbolics.jacobian(x_dot, u)

    f = build_function(x_dot, x, u, expression=Val{false})[1]
    A = build_function(A_sym, x, u, expression=Val{false})[1]
    B = build_function(B_sym, x, u, expression=Val{false})[1]   
    
    # Cost function
    # problem_set_running_cost!(
    #     pbm, :ptr, (t, k, x, u, p, pbm) -> #dot(x[4:6] - v_N, x[4:6] - v_N) # I don't think you can use norm, package needs to be updated or smth.
    #     #dot([zeros(3, 1); 2 * (x[4:6] - v_N)], f(x, u) * p[2]);
    #     #dot(x[4:6], g + u) * p[2]
    # )
    problem_set_terminal_cost!(
        pbm, (x, p, pbm) -> dot(x[4:6] - v_N, x[4:6] - v_N)
    )
    # Dynamics
    problem_set_dynamics!(
        pbm,
        # f
        (t, k, x, u, p, pbm) ->
            f(x, u)*p[2],
        # df/dx
        (t, k, x, u, p, pbm) ->
            A(x, u)*p[2],
        # df/du
        (t, k, x, u, p, pbm) ->
            B(x, u)*p[2],
        # df/dp
        (t, k, x, u, p, pbm) ->
            zeros(pbm.nx, pbm.np)*p[2])

    # Quaternion re-normalization on numerical integration step
    problem_set_integration_action!(
        pbm, 7:10, # indices of quaternion
        (x, pbm) -> begin
            xn = x / norm(x)
            return xn
        end)

    # Boundary conditions
    problem_set_bc!(
        pbm, :ic, # Initial condition
        (x, p, pbm) -> x - [r_0 + v_0 * p[1] + p[1]^2 * g / 2; v_0 + p[1] * g; q_0; w_0],
        (x, p, pbm) -> I(pbm.nx), # Jacobian wrt x
        (x, p, pbm) -> - [[v_0 + g * p[1]; g; zeros(pbm.nx - 6)] zeros(pbm.nx, pbm.np - 1)] # Jacobian wrt p 
    )

    problem_set_bc!(
        pbm, :tc,  # Terminal condition
        (x, p, pbm) -> [x[3] - r_N[3];
        x[8:9] - q_N[2:3];
        x[11:13] - w_N],
        (x, p, pbm) -> [zeros(1, 2) 1 zeros(1, pbm.nx - 3); 
        zeros(2, 7) I(2) zeros(2, pbm.nx - 9);
        zeros(3, 10) I(3)], 
        (x, p, pbm) -> zeros(6, pbm.np) # Jacobian wrt p
    )
    
    # Convex State Constraints
    problem_set_X!(
        pbm, (t, k, x, p, pbm, ocp) -> begin

        @add_constraint(
            ocp, NONPOS, "height >= 0", (x[3],), begin
            local height = arg[1]
            - height
            end)

        @add_constraint(
            ocp, NONPOS, "t_coast >= 0", (p[1],), begin
                local t_coast = arg[1]
                - t_coast
            end)

        @add_constraint(
            ocp, NONPOS, "t_burn >= 3.38", (p[2],), begin
                local t_burn = arg[1]
                3.38 - t_burn[1]
            end)

        @add_constraint(
            ocp, SOC, "|w| < w_max", (x[11:13],), begin
                local w = arg[1]
                [pi / 2; w]
            end)
        end)

    # Convex Input Constraints
    problem_set_U!(
        pbm, (t, k, u, p, pbm, ocp) -> begin

        @add_constraint(
            ocp, NONPOS, "roll torque <= Max", (u[4],), begin # u is the descision variable for the constraint, but t isn't so don't include?
                local u = arg[1]
                u[1] - 1.0
            end)
            
        @add_constraint(
            ocp, SOC, "Thrust Gimal angle < delta_max", (u[1:3],), begin
                local u = arg[1]
                [u[3] / cos(pi * 5/180); u]
            end)
        end)

    # Constraints s() <= 0
    problem_set_s!(
        pbm, algo,
        # s
        (t, k, x, u, p, pbm) -> [norm(u)^2 - Acceleration(t * p[2])^2], # need to work out t coast max
        # ds/dx
        (t, k, x, u, p, pbm) -> zeros(1, pbm.nx), 
        # ds/du
        (t, k, x, u, p, pbm) -> reshape(2 * u, 1, :), #needs to be matrix
        # ds/dp
        (t, k, x, u, p, pbm) -> - [0 t * central_fdm(5, 1)(Acceleration, t * p[2])] # df(t * p)/dp = df(z)/dz * dz/dp
    )  

    # :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    # :: SCvx algorithm parameters :::::::::::::::::::::::::::::::::::::::::::::::::
    # :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    if algo == :scvx
        N = floor(Int, 3.45 / 0.1) + 1
        Nsub = 100
        iter_max = 30
        disc_method = FOH
        λ = 5e3
        ρ_0 = 0.0
        ρ_1 = 0.1
        ρ_2 = 0.7
        β_sh = 2.0
        β_gr = 2.0
        η_init = 1.0
        η_lb = 1e-8
        η_ub = 10.0
        ε_abs = 1e-8
        ε_rel = 1e-5
        feas_tol = 5e-3
        q_tr = Inf
        q_exit = Inf
        solver = ECOS
        solver_options = Dict("verbose"=>0, "maxit"=>1000)
        pars = Solvers.SCvx.Parameters(N, Nsub, iter_max, disc_method, λ, ρ_0, ρ_1, ρ_2, β_sh, β_gr,
                            η_init, η_lb, η_ub, ε_abs, ε_rel, feas_tol, q_tr,
                            q_exit, solver, solver_options)

        # :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
        # :: Solve trajectory generation problem ::::::::::::::::::::::::::::::::::::::
        # :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

        scvx_pbm = Solvers.SCvx.create(pars, pbm)
        sol, history = Solvers.SCvx.solve(scvx_pbm)
    elseif algo == :ptr
        N, Nsub = floor(Int, 3.45 / 0.05) + 1, 10 # see LanderSolid.m, dt needs to be low. We need many degrees of freedom on u
        iter_max = 5
        disc_method = FOH
        wvc, wtr = 1e3, 1e0 # wtr is important, needs to be small but too small and we get problems. 
        feas_tol = 1e-2
        ε_abs, ε_rel = 1e-5, 1e-3
        q_tr = Inf
        q_exit = Inf
        solver, options = ECOS, Dict("verbose"=>0)
        pars = Solvers.PTR.Parameters(
            N, Nsub, iter_max, disc_method, wvc, wtr, ε_abs,
            ε_rel, feas_tol, q_tr, q_exit, solver, options)
        # Create and solve the problem
        ptr_pbm = Solvers.PTR.create(pars, pbm)
        sol, history = Solvers.PTR.solve(ptr_pbm)
    end
    return sol
end

function set_scale!(pbm::TrajectoryProblem)::Nothing #VERY IMPORTANT, is it?
    advise! = problem_advise_scale!

    # States
    advise!(pbm, :state, 1, (-1000.0, 1000.0))
    advise!(pbm, :state, 2, (-1000.0, 1000.0))
    advise!(pbm, :state, 3, (0.0, 1000.0))
    advise!(pbm, :state, 4, (-100.0, 100.0))
    advise!(pbm, :state, 5, (-100.0, 100.0))
    advise!(pbm, :state, 6, (-100.0, 100.0))

    advise!(pbm, :state, 7, (-1.0, 1.0))
    advise!(pbm, :state, 8, (-1.0, 1.0))
    advise!(pbm, :state, 9, (-1.0, 1.0))
    advise!(pbm, :state, 10, (-1.0, 1.0))
    advise!(pbm, :state, 11, (-10.0, 10.0))
    advise!(pbm, :state, 12, (-10.0, 10.0))
    advise!(pbm, :state, 13, (-10.0, 00.0))

    # Inputs
    advise!(pbm, :input, 1, (-25.0, 25.0))
    advise!(pbm, :input, 2, (-25.0, 25.0))
    advise!(pbm, :input, 3, (-25.0, 25.0))
    advise!(pbm, :input, 4, (-5.0, 5.0))

    # Parameters
    advise!(pbm, :parameter, 1, (0.0, 10.0))
    advise!(pbm, :parameter, 2, (3.38, 10.0))

    return nothing
end

function print(solution)
    println("Coast time (s): ", solution.p[1])
    println("Burn time (s): ", solution.p[2])

    v_N =[0; 0; 0];
    println("Impact Velocity Magnitude (m/s): ", solution.cost^0.5)
end

function plot(solution)
    plotlyjs()
    plot(solution.td, ThrottleLevel(norm.(eachcol(solution.ud[1:3, :])), Acceleration(solution.td) ) )
end

function save(solution)
    r_0 = [20; -4; 30];	# position vector, m
    v_0 = [4; -3; 0];		# velocity vector, m/s
    q_0 = [1; 0; 0; 0];
    w_0 = [0; 0; 0]

    npzwrite("x.npy", transpose([[r_0; v_0; q_0; w_0] solution.xd]))
    npzwrite("u.npy", transpose([[0; 0; 0; 0] solution.ud]))
    npzwrite("t.npy", transpose([0; solution.p[1] .+ solution.p[2] * solution.td]))
end