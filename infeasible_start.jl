using RigidBodyDynamics
using ForwardDiff
using Plots
using Base.Test

function bias(solver::Solver,X_desired::Array{Float64,2})
    U = zeros(solver.model.m,solver.N-1)
    bias(solver,X_desired,U)
end

function bias(solver::Solver,X_desired::Array{Float64,2},U::Array{Float64,2})
    b = zeros(solver.model.n,solver.N-1)
    X = zeros(solver.model.n,solver.N)
    X[:,1] = X_desired[:,1]
    for k = 1:solver.N-1
        X[:,k+1] = solver.fd(X[:,k],U[:,k])
        b[:,k] = X_desired[:,k+1] - X[:,k+1]
        X[:,k+1] += b[:,k]
    end
    X, b
end

function rollout!(res::SolverResults,solver::InfeasibleSolver)
    X = res.X; U = res.U

    X[:,1] = solver.obj.x0
    for k = 1:solver.N-1
        if solver.opts.inplace_dynamics
            solver.fd(view(X,:,k+1), X[:,k], U[1:solver.model.m,k]) + U[solver.model.m+1:end,k]
        else
            X[:,k+1] = solver.fd(X[:,k], U[1:solver.model.m,k]) + U[solver.model.m+1:end,k]
        end
    end
end

function rollout!(res::SolverResults,solver::InfeasibleSolver,alpha::Float64)
    # pull out solver/result values
    N = solver.N
    X = res.X; U = res.U; K = res.K; d = res.d; X_ = res.X_; U_ = res.U_

    X_[:,1] = solver.obj.x0;
    for k = 2:N
        a = alpha*d[:,k-1]
        delta = X_[:,k-1] - X[:,k-1]
        U_[:, k-1] = U[:, k-1] - K[:,:,k-1]*delta - a

        if solver.opts.inplace_dynamics
            solver.fd(view(X_,:,k) ,X_[:,k-1], U_[1:solver.model.m,k-1]) + U[solver.model.m+1:end,k-1]
        else
            X_[:,k] = solver.fd(X_[:,k-1], U_[1:solver.model.m,k-1]) + U[solver.model.m+1:end,k-1]
        end

        if ~all(isfinite, X_[:,k]) || ~all(isfinite, U_[:,k-1])
            return false
        end
    end
    return true
end
# overloaded cost function to accomodate Augmented Lagrance method
function cost(solver,X::Array{Float64,2},U::Array{Float64,2})
    # pull out solver/objective values
    N = solver.N; Q = solver.obj.Q; R = solver.obj.R; xf = solver.obj.xf; Qf = solver.obj.Qf

    J = 0.0
    for k = 1:N-1
      J += 0.5*(X[:,k] - xf)'*Q*(X[:,k] - xf) + 0.5*U[:,k]'*R*U[:,k]
    end
    J += 0.5*(X[:,N] - xf)'*Qf*(X[:,N] - xf)
    return J
end
function cost(solver,X::Array{Float64,2},U::Array{Float64,2},C::Array{Float64,2},I_mu::Array{Float64,3},LAMBDA::Array{Float64,2})
    J = cost(solver,X,U)
    for k = 1:solver.N-1
        J += 0.5*(C[:,k]'*I_mu[:,:,k]*C[:,k] + LAMBDA[:,k]'*C[:,k])
    end
    return J
end

function cost(solver, res::ConstrainedResults)
    J = cost(solver,res.X,res.U)
    for k = 1:solver.N-1
        J += 0.5*(res.C[:,k]'*res.Iμ[:,:,k]*res.C[:,k] + res.LAMBDA[:,k]'*res.C[:,k])
    end
    J += 0.5*(res.CN'*res.IμN*res.CN + res.λN'*res.CN)
    return J
end

function backwardpass!(res::ConstrainedResults, solver::InfeasibleSolver, constraint_jacobian::Function, pI::Int)
    N = solver.N
    n = solver.model.n
    m = solver.model.m
    Q = solver.obj.Q
    R = solver.obj.R
    xf = solver.obj.xf
    Qf = solver.obj.Qf

    # pull out values from results
    X = res.X; U = res.U; K = res.K; d = res.d; C = res.C; Iμ = res.Iμ; LAMBDA = res.LAMBDA
    # p = size(C,1)
    # pI = 2*m  # Number of inequality constraints. TODO this needs to be automatic
    # pE = n

    Cx, Cu = constraint_jacobian(res.X[:,N])
    S = Qf + Cx'*res.IμN*Cx
    s = Qf*(X[:,N] - xf) + Cx'*res.IμN*res.CN + Cx'*res.λN
    v1 = 0.
    v2 = 0.

    mu = 0.
    k = N-1
    while k >= 1
        lx = Q*(X[:,k] - xf)
        lu = R*(U[:,k])
        lxx = Q
        luu = R
        fx, fu = solver.F(X[:,k], U[1:m,k])
        fu = [fu eye(solver.model.n)]
        Qx = lx + fx'*s
        Qu = lu + fu'*s
        Qxx = lxx + fx'*S*fx
        Quu = Hermitian(luu + fu'*(S + mu*eye(n))*fu)
        Qux = fu'*(S + mu*eye(n))*fx

        # regularization
        if ~isposdef(Quu)
            mu = mu + solver.opts.mu_regularization;
            k = N-1
            if solver.opts.verbose
                println("regularized")
            end
        end

        # Constraints
        Cx, Cu = constraint_jacobian(X[:,k], U[:,k])
        Qx += Cx'*Iμ[:,:,k]*C[:,k] + Cx'*LAMBDA[:,k]
        Qu += Cu'*Iμ[:,:,k]*C[:,k] + Cu'*LAMBDA[:,k]
        Qxx += Cx'*Iμ[:,:,k]*Cx
        Quu += Cu'*Iμ[:,:,k]*Cu
        Qux += Cu'*Iμ[:,:,k]*Cx
        K[:,:,k] = Quu\Qux
        d[:,k] = Quu\Qu
        s = (Qx' - Qu'*K[:,:,k] + d[:,k]'*Quu*K[:,:,k] - d[:,k]'*Qux)'
        S = Qxx + K[:,:,k]'*Quu*K[:,:,k] - K[:,:,k]'*Qux - Qux'*K[:,:,k]

        # terms for line search
        v1 += float(d[:,k]'*Qu)[1]
        v2 += float(d[:,k]'*Quu*d[:,k])

        k = k - 1;
    end
    return v1, v2
end

function forwardpass!(res::ConstrainedResults, solver::InfeasibleSolver, v1::Float64, v2::Float64,c_fun)

    # Pull out values from results
    X = res.X
    U = res.U
    K = res.K
    d = res.d
    X_ = res.X_
    U_ = res.U_
    C = res.C
    Iμ = res.Iμ
    LAMBDA = res.LAMBDA
    MU = res.MU

    # Compute original cost
    # J_prev = cost(solver, X, U, C, Iμ, LAMBDA)
    J_prev = cost(solver, res)

    pI = 2*solver.model.m # TODO change this

    J = Inf
    alpha = 1.0
    iter = 0
    dV = Inf
    z = 0.

    while z < solver.opts.c1 || z > solver.opts.c2
        rollout!(res,solver,alpha)

        # Calcuate cost
        # update_constraints!(C,Iμ,c_fun,X_,U_,LAMBDA,MU,pI)
        update_constraints!(res, c_fun, pI, X_, U_)
        # J = cost(solver, X_, U_, C, Iμ, LAMBDA)
        J = cost(solver,res)
        dV = alpha*v1 + (alpha^2)*v2/2.
        z = (J_prev - J)/dV[1,1]
        alpha = alpha/2.
        iter = iter + 1

        if iter > solver.opts.iterations_linesearch
            if solver.opts.verbose
                println("max iterations (forward pass)")
            end
            break
        end
        iter += 1
    end

    if solver.opts.verbose
        println("New cost: $J")
        println("- Expected improvement: $(dV[1])")
        println("- Actual improvement: $(J_prev-J)")
        println("- (z = $z)\n")
    end

    return J

end

function solve_infeasible(solver::iLQR.Solver,X_init::Array{Float64,2},U0::Array{Float64,2})
    N = solver.N
    n = solver.model.n
    m = solver.model.m
    m_aug = n+m

    # set up infeasible state trajectory
    solver.opts.infeasible_start = true
    _, b = bias(solver,X_init,U0)
    solver.obj.x0 = X_init[:,1]
    U = [U0; b]

    X = copy(X_init)
    X_ = similar(X)
    U_ = similar(U)
    K = zeros(m_aug,n,N-1)
    d = zeros(m_aug,N-1)
    J = 0.

    # cache option
    if solver.opts.cache
        i_counter = 1
        X_cache = zeros(n,N,solver.opts.iterations*solver.opts.iterations_outerloop)
        U_cache = zeros(m_aug,N-1,solver.opts.iterations*solver.opts.iterations_outerloop)
        X_cache[:,:,i_counter] = copy(X)
        U_cache[:,:,i_counter] = copy(U)
        i_counter += 1
    end

    ## Constraints

    # add infeasible constraints
    function c_infeasible(x,u)
        u[m+1:end]
    end

    Rnew = solver.obj.R[1,1]*eye(solver.model.m+solver.model.n) # update R matrix for augmented control vector
    Rnew[1:solver.model.m,1:solver.model.m] .= solver.obj.R
    obj = update_objective_infeasible(solver.obj,Rnew,cE=c_infeasible) # FIX
    solver_infeasible = InfeasibleSolver(solver,obj)

    p = solver_infeasible.obj.p
    pI = solver_infeasible.obj.pI
    u_min = solver_infeasible.obj.u_min
    u_max = solver_infeasible.obj.u_max
    xf = solver_infeasible.obj.xf
    #
    C = zeros(p,N-1)
    Iμ = zeros(p,p,N-1)
    LAMBDA = zeros(p,N-1)
    MU = ones(p,N-1)

    CN = zeros(n)  # TODO allow more general terminal constraint
    IμN = zeros(n,n)
    λN = zeros(n)
    μN = zeros(n)
    results = ConstrainedResults(n,m,p,N)
    results = ConstrainedResults(X,U,K,d,X_,U_,C,Iμ,LAMBDA,MU,CN,IμN,λN,μN)

    function c_control(x,u)
        [u_max - u[1:m];
         u[1:m] - u_min]
    end

    function c_fun(x,u)
        [c_control(x,u); c_infeasible(x,u)]
    end

    function c_fun(x)
        x - xf
    end

    fx_control = zeros(2m,n)
    fu_control = zeros(2m,m_aug)
    fu_control[1:m, 1:m] = -eye(m)
    fu_control[m+1:end,1:m] = eye(m)

    fx_infeasible = zeros(n,n)
    fu_infeasible = zeros(n,m_aug)
    fu_infeasible[:,m+1:end] = eye(n)

    fx = zeros(p,n)
    fu = zeros(p,m_aug)

    fx_N = eye(n)  # Jacobian of final state

    function constraint_jacobian(x::Array,u::Array)
        fx[1:2m, :] = fx_control
        fu[1:2m, :] = fu_control

        fx[2m+1:end,:] = fx_infeasible
        fu[2m+1:end,:] = fu_infeasible
        return fx, fu
    end

    function constraint_jacobian(x::Array)
        return fx_N
    end

    ### SOLVER
    # no initial roll-out required for infeasible start

    # Outer Loop
    for k = 1:solver.opts.iterations_outerloop


        update_constraints!(results, c_fun, pI, X, U)
        mask = copy(Iμ)
        mask[mask.>0] = 1.0
        maxest_c = 0
        for i = 1:N-1
            max_c = maximum(abs.(mask[:,:,i]*C[:,i]))
            if max_c > maxest_c
                maxest_c = max_c
            end
        end
        mask2 = copy(IμN)
        mask2[mask2.>0] = 1.0
        max_c = maximum(abs.(mask2*CN))
        if max_c > maxest_c
            maxest_c = max_c
        end

        println("max constraint violation: $maxest_c")
        if maxest_c < solver.opts.eps_constraint
            println("max constraint violation less than threshold:$(maxest_c)")
           break
        end

        J_prev = cost(solver_infeasible, X, U, C, Iμ, LAMBDA)
        if solver.opts.verbose
            println("Cost ($k): $J_prev\n")
        end

        for i = 1:solver.opts.iterations
            if solver.opts.verbose
                println("--Iteration: $k-($i)--")
            end
            v1, v2 = backwardpass!(results, solver_infeasible, constraint_jacobian, pI)
            J = forwardpass!(results, solver_infeasible, v1, v2, c_fun)
            X .= X_
            U .= U_
            dJ = copy(abs(J-J_prev))
            J_prev = copy(J)

            if solver.opts.cache
                X_cache[:,:,i_counter] = copy(X)
                U_cache[:,:,i_counter] = copy(U)
                i_counter += 1
            end

            if dJ < solver.opts.eps
                if solver.opts.verbose
                    println("   eps criteria met at iteration: $i\n")
                end
                break
            end
        end

        # Outer Loop - update lambda, mu
        update_constraints!(results, c_fun, pI, X, U)
        for jj = 1:N-1
            for ii = 1:p
                if ii <= pI
                    LAMBDA[ii,jj] .+= MU[ii,jj]*min(C[ii,jj],0) # TODO handle equality constraints
                else
                    LAMBDA[ii,jj] .+= MU[ii,jj]*C[ii,jj]
                end
                MU[ii,jj] += 100.0
            end
        end
        λN .+= μN.*CN
        μN .+= 10.0
    end
    if solver.opts.cache
        return X, U, X_cache, U_cache, i_counter
    else
        return X, U
    end

end