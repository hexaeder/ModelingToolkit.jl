"""
$(TYPEDEF)

A system of difference equations.

# Fields
$(FIELDS)

# Example

```
using ModelingToolkit

@parameters σ=28.0 ρ=10.0 β=8/3 δt=0.1
@variables t x(t)=1.0 y(t)=0.0 z(t)=0.0
D = Difference(t; dt=δt)

eqs = [D(x) ~ σ*(y-x),
       D(y) ~ x*(ρ-z)-y,
       D(z) ~ x*y - β*z]

@named de = DiscreteSystem(eqs,t,[x,y,z],[σ,ρ,β]; tspan = (0, 1000.0)) # or
@named de = DiscreteSystem(eqs)
```
"""
struct DiscreteSystem <: AbstractTimeDependentSystem
    """
    A tag for the system. If two systems have the same tag, then they are
    structurally identical.
    """
    tag::UInt
    """The differential equations defining the discrete system."""
    eqs::Vector{Equation}
    """Independent variable."""
    iv::BasicSymbolic{Real}
    """Dependent (state) variables. Must not contain the independent variable."""
    states::Vector
    """Parameter variables. Must not contain the independent variable."""
    ps::Vector
    """Time span."""
    tspan::Union{NTuple{2, Any}, Nothing}
    """Array variables."""
    var_to_name::Any
    """Control parameters (some subset of `ps`)."""
    ctrls::Vector
    """Observed states."""
    observed::Vector{Equation}
    """
    The name of the system
    """
    name::Symbol
    """
    The internal systems. These are required to have unique names.
    """
    systems::Vector{DiscreteSystem}
    """
    The default values to use when initial conditions and/or
    parameters are not supplied in `DiscreteProblem`.
    """
    defaults::Dict
    """
    Inject assignment statements before the evaluation of the RHS function.
    """
    preface::Any
    """
    Type of the system.
    """
    connector_type::Any
    """
    Metadata for the system, to be used by downstream packages.
    """
    metadata::Any
    """
    Metadata for MTK GUI.
    """
    gui_metadata::Union{Nothing, GUIMetadata}
    """
    Cache for intermediate tearing state.
    """
    tearing_state::Any
    """
    Substitutions generated by tearing.
    """
    substitutions::Any
    """
    If a model `sys` is complete, then `sys.x` no longer performs namespacing.
    """
    complete::Bool
    """
    The hierarchical parent system before simplification.
    """
    parent::Any

    function DiscreteSystem(tag, discreteEqs, iv, dvs, ps, tspan, var_to_name, ctrls,
            observed,
            name,
            systems, defaults, preface, connector_type,
            metadata = nothing, gui_metadata = nothing,
            tearing_state = nothing, substitutions = nothing,
            complete = false, parent = nothing; checks::Union{Bool, Int} = true)
        if checks == true || (checks & CheckComponents) > 0
            check_variables(dvs, iv)
            check_parameters(ps, iv)
        end
        if checks == true || (checks & CheckUnits) > 0
            u = __get_unit_type(dvs, ps, iv, ctrls)
            check_units(u, discreteEqs)
        end
        new(tag, discreteEqs, iv, dvs, ps, tspan, var_to_name, ctrls, observed, name,
            systems,
            defaults,
            preface, connector_type, metadata, gui_metadata,
            tearing_state, substitutions, complete, parent)
    end
end

"""
    $(TYPEDSIGNATURES)

Constructs a DiscreteSystem.
"""
function DiscreteSystem(eqs::AbstractVector{<:Equation}, iv, dvs, ps;
        controls = Num[],
        observed = Num[],
        systems = DiscreteSystem[],
        tspan = nothing,
        name = nothing,
        default_u0 = Dict(),
        default_p = Dict(),
        defaults = _merge(Dict(default_u0), Dict(default_p)),
        preface = nothing,
        connector_type = nothing,
        metadata = nothing,
        gui_metadata = nothing,
        kwargs...)
    name === nothing &&
        throw(ArgumentError("The `name` keyword must be provided. Please consider using the `@named` macro"))
    eqs = scalarize(eqs)
    iv′ = value(iv)
    dvs′ = value.(dvs)
    ps′ = value.(ps)
    ctrl′ = value.(controls)

    if !(isempty(default_u0) && isempty(default_p))
        Base.depwarn("`default_u0` and `default_p` are deprecated. Use `defaults` instead.",
            :DiscreteSystem, force = true)
    end
    defaults = todict(defaults)
    defaults = Dict(value(k) => value(v) for (k, v) in pairs(defaults))

    var_to_name = Dict()
    process_variables!(var_to_name, defaults, dvs′)
    process_variables!(var_to_name, defaults, ps′)
    isempty(observed) || collect_var_to_name!(var_to_name, (eq.lhs for eq in observed))

    sysnames = nameof.(systems)
    if length(unique(sysnames)) != length(sysnames)
        throw(ArgumentError("System names must be unique."))
    end
    DiscreteSystem(Threads.atomic_add!(SYSTEM_COUNT, UInt(1)),
        eqs, iv′, dvs′, ps′, tspan, var_to_name, ctrl′, observed, name, systems,
        defaults, preface, connector_type, metadata, gui_metadata, kwargs...)
end

function DiscreteSystem(eqs, iv = nothing; kwargs...)
    eqs = scalarize(eqs)
    # NOTE: this assumes that the order of algebraic equations doesn't matter
    diffvars = OrderedSet()
    allstates = OrderedSet()
    ps = OrderedSet()
    # reorder equations such that it is in the form of `diffeq, algeeq`
    diffeq = Equation[]
    algeeq = Equation[]
    # initial loop for finding `iv`
    if iv === nothing
        for eq in eqs
            if !(eq.lhs isa Number) # assume eq.lhs is either Differential or Number
                iv = iv_from_nested_difference(eq.lhs)
                break
            end
        end
    end
    iv = value(iv)
    iv === nothing && throw(ArgumentError("Please pass in independent variables."))
    for eq in eqs
        collect_vars_difference!(allstates, ps, eq.lhs, iv)
        collect_vars_difference!(allstates, ps, eq.rhs, iv)
        if isdifferenceeq(eq)
            diffvar, _ = var_from_nested_difference(eq.lhs)
            isequal(iv, iv_from_nested_difference(eq.lhs)) ||
                throw(ArgumentError("A DiscreteSystem can only have one independent variable."))
            diffvar in diffvars &&
                throw(ArgumentError("The difference variable $diffvar is not unique in the system of equations."))
            push!(diffvars, diffvar)
            push!(diffeq, eq)
        else
            push!(algeeq, eq)
        end
    end
    algevars = setdiff(allstates, diffvars)
    # the orders here are very important!
    return DiscreteSystem(append!(diffeq, algeeq), iv,
        collect(Iterators.flatten((diffvars, algevars))), ps; kwargs...)
end

"""
    $(TYPEDSIGNATURES)

Generates an DiscreteProblem from an DiscreteSystem.
"""
function SciMLBase.DiscreteProblem(sys::DiscreteSystem, u0map = [], tspan = get_tspan(sys),
        parammap = SciMLBase.NullParameters();
        eval_module = @__MODULE__,
        eval_expression = true,
        use_union = false,
        kwargs...)
    dvs = states(sys)
    ps = parameters(sys)
    eqs = equations(sys)
    eqs = linearize_eqs(sys, eqs)
    iv = get_iv(sys)

    defs = defaults(sys)
    defs = mergedefaults(defs, parammap, ps)
    defs = mergedefaults(defs, u0map, dvs)

    u0 = varmap_to_vars(u0map, dvs; defaults = defs, tofloat = false)
    p = varmap_to_vars(parammap, ps; defaults = defs, tofloat = false, use_union)

    rhss = [eq.rhs for eq in eqs]
    u = dvs

    f_gen = generate_function(sys; expression = Val{eval_expression},
        expression_module = eval_module)
    f_oop, _ = (drop_expr(@RuntimeGeneratedFunction(eval_module, ex)) for ex in f_gen)
    f(u, p, iv) = f_oop(u, p, iv)
    fd = DiscreteFunction(f; syms = Symbol.(dvs), indepsym = Symbol(iv),
        paramsyms = Symbol.(ps), sys = sys)
    DiscreteProblem(fd, u0, tspan, p; kwargs...)
end

function linearize_eqs(sys, eqs = get_eqs(sys); return_max_delay = false)
    unique_states = unique(operation.(states(sys)))
    max_delay = Dict(v => 0.0 for v in unique_states)

    r = @rule ~t::(t -> istree(t) && any(isequal(operation(t)), operation.(states(sys))) && is_delay_var(get_iv(sys), t)) => begin
        delay = get_delay_val(get_iv(sys), first(arguments(~t)))
        if delay > max_delay[operation(~t)]
            max_delay[operation(~t)] = delay
        end
        nothing
    end
    SymbolicUtils.Postwalk(r).(rhss(eqs))

    if any(values(max_delay) .> 0)
        dts = Dict(v => Any[] for v in unique_states)
        state_ops = Dict(v => Any[] for v in unique_states)
        for v in unique_states
            for eq in eqs
                if isdifferenceeq(eq) && istree(arguments(eq.lhs)[1]) &&
                   isequal(v, operation(arguments(eq.lhs)[1]))
                    append!(dts[v], [operation(eq.lhs).dt])
                    append!(state_ops[v], [operation(eq.lhs)])
                end
            end
        end

        all(length.(unique.(values(state_ops))) .<= 1) ||
            error("Each state should be used with single difference operator.")

        dts_gcd = Dict()
        for v in keys(dts)
            dts_gcd[v] = (length(dts[v]) > 0) ? first(dts[v]) : nothing
        end

        lin_eqs = [v(get_iv(sys) - (t)) ~ v(get_iv(sys) - (t - dts_gcd[v]))
                   for v in unique_states if max_delay[v] > 0 && dts_gcd[v] !== nothing
                   for t in collect(max_delay[v]:(-dts_gcd[v]):0)[1:(end - 1)]]
        eqs = vcat(eqs, lin_eqs)
    end
    if return_max_delay
        return eqs, max_delay
    end
    eqs
end

function get_delay_val(iv, x)
    delay = x - iv
    isequal(delay > 0, true) && error("Forward delay not permitted")
    return -delay
end

function generate_function(sys::DiscreteSystem, dvs = states(sys), ps = parameters(sys);
        kwargs...)
    eqs = equations(sys)
    check_operator_variables(eqs, Difference)
    rhss = [eq.rhs for eq in eqs]

    u = map(x -> time_varying_as_func(value(x), sys), dvs)
    p = map(x -> time_varying_as_func(value(x), sys), ps)
    t = get_iv(sys)

    build_function(rhss, u, p, t; kwargs...)
    pre, sol_states = get_substitutions_and_solved_states(sys)
    build_function(rhss, u, p, t; postprocess_fbody = pre, states = sol_states, kwargs...)
end

"""
```julia
SciMLBase.DiscreteFunction{iip}(sys::DiscreteSystem, dvs = states(sys),
                                ps = parameters(sys);
                                version = nothing,
                                kwargs...) where {iip}
```

Create a `DiscreteFunction` from the [`DiscreteSystem`](@ref). The arguments
`dvs` and `ps` are used to set the order of the dependent variable and parameter
vectors, respectively.
"""
function SciMLBase.DiscreteFunction(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunction{true}(sys, args...; kwargs...)
end

function SciMLBase.DiscreteFunction{true}(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunction{true, SciMLBase.AutoSpecialize}(sys, args...; kwargs...)
end

function SciMLBase.DiscreteFunction{false}(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunction{false, SciMLBase.FullSpecialize}(sys, args...; kwargs...)
end

function SciMLBase.DiscreteFunction{iip, specialize}(sys::DiscreteSystem,
        dvs = states(sys),
        ps = parameters(sys),
        u0 = nothing;
        version = nothing,
        p = nothing,
        t = nothing,
        eval_expression = true,
        eval_module = @__MODULE__,
        analytic = nothing,
        simplify = false,
        kwargs...) where {iip, specialize}
    f_gen = generate_function(sys, dvs, ps; expression = Val{eval_expression},
        expression_module = eval_module, kwargs...)
    f_oop, f_iip = eval_expression ?
                   (drop_expr(@RuntimeGeneratedFunction(eval_module, ex)) for ex in f_gen) :
                   f_gen
    f(u, p, t) = f_oop(u, p, t)
    f(du, u, p, t) = f_iip(du, u, p, t)

    if specialize === SciMLBase.FunctionWrapperSpecialize && iip
        if u0 === nothing || p === nothing || t === nothing
            error("u0, p, and t must be specified for FunctionWrapperSpecialize on DiscreteFunction.")
        end
        f = SciMLBase.wrapfun_iip(f, (u0, u0, p, t))
    end

    observedfun = let sys = sys, dict = Dict()
        function generate_observed(obsvar, u, p, t)
            obs = get!(dict, value(obsvar)) do
                build_explicit_observed_function(sys, obsvar)
            end
            obs(u, p, t)
        end
    end

    DiscreteFunction{iip, specialize}(f;
        sys = sys,
        syms = Symbol.(states(sys)),
        indepsym = Symbol(get_iv(sys)),
        paramsyms = Symbol.(ps),
        observed = observedfun,
        analytic = analytic)
end

"""
```julia
DiscreteFunctionExpr{iip}(sys::DiscreteSystem, dvs = states(sys),
                          ps = parameters(sys);
                          version = nothing,
                          kwargs...) where {iip}
```

Create a Julia expression for an `DiscreteFunction` from the [`DiscreteSystem`](@ref).
The arguments `dvs` and `ps` are used to set the order of the dependent
variable and parameter vectors, respectively.
"""
struct DiscreteFunctionExpr{iip} end
struct DiscreteFunctionClosure{O, I} <: Function
    f_oop::O
    f_iip::I
end
(f::DiscreteFunctionClosure)(u, p, t) = f.f_oop(u, p, t)
(f::DiscreteFunctionClosure)(du, u, p, t) = f.f_iip(du, u, p, t)

function DiscreteFunctionExpr{iip}(sys::DiscreteSystem, dvs = states(sys),
        ps = parameters(sys), u0 = nothing;
        version = nothing, p = nothing,
        linenumbers = false,
        simplify = false,
        kwargs...) where {iip}
    f_oop, f_iip = generate_function(sys, dvs, ps; expression = Val{true}, kwargs...)

    fsym = gensym(:f)
    _f = :($fsym = $DiscreteFunctionClosure($f_oop, $f_iip))

    ex = quote
        $_f
        DiscreteFunction{$iip}($fsym,
            syms = $(Symbol.(states(sys))),
            indepsym = $(QuoteNode(Symbol(get_iv(sys)))),
            paramsyms = $(Symbol.(parameters(sys))))
    end
    !linenumbers ? Base.remove_linenums!(ex) : ex
end

function DiscreteFunctionExpr(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunctionExpr{true}(sys, args...; kwargs...)
end

function process_DiscreteProblem(constructor, sys::DiscreteSystem, u0map, parammap;
        version = nothing,
        linenumbers = true, parallel = SerialForm(),
        eval_expression = true,
        use_union = false,
        tofloat = !use_union,
        kwargs...)
    eqs = equations(sys)
    dvs = states(sys)
    ps = parameters(sys)

    u0, p, defs = get_u0_p(sys, u0map, parammap; tofloat, use_union)

    check_eqs_u0(eqs, dvs, u0; kwargs...)

    f = constructor(sys, dvs, ps, u0;
        linenumbers = linenumbers, parallel = parallel,
        syms = Symbol.(dvs), paramsyms = Symbol.(ps),
        eval_expression = eval_expression, kwargs...)
    return f, u0, p
end

function DiscreteProblemExpr(sys::DiscreteSystem, args...; kwargs...)
    DiscreteProblemExpr{true}(sys, args...; kwargs...)
end

function DiscreteProblemExpr{iip}(sys::DiscreteSystem, u0map, tspan,
        parammap = DiffEqBase.NullParameters();
        check_length = true,
        kwargs...) where {iip}
    f, u0, p = process_DiscreteProblem(DiscreteFunctionExpr{iip}, sys, u0map, parammap;
        check_length, kwargs...)
    linenumbers = get(kwargs, :linenumbers, true)

    ex = quote
        f = $f
        u0 = $u0
        p = $p
        tspan = $tspan
        DiscreteProblem(f, u0, tspan, p; $(filter_kwargs(kwargs)...))
    end
    !linenumbers ? Base.remove_linenums!(ex) : ex
end
