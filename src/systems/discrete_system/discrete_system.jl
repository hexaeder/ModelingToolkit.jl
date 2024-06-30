"""
$(TYPEDEF)
A system of difference equations.
# Fields
$(FIELDS)
# Example
```
using ModelingToolkit
using ModelingToolkit: t_nounits as t
@parameters σ=28.0 ρ=10.0 β=8/3 δt=0.1
@variables x(t)=1.0 y(t)=0.0 z(t)=0.0
k = ShiftIndex(t)
eqs = [x(k+1) ~ σ*(y-x),
       y(k+1) ~ x*(ρ-z)-y,
       z(k+1) ~ x*y - β*z]
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
    unknowns::Vector
    """Parameter variables. Must not contain the independent variable."""
    ps::Vector
    """Time span."""
    tspan::Union{NTuple{2, Any}, Nothing}
    """Array variables."""
    var_to_name::Any
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
    A mapping from dependent parameters to expressions describing how they are calculated from
    other parameters.
    """
    parameter_dependencies::Union{Nothing, Dict}
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
    Cached data for fast symbolic indexing.
    """
    index_cache::Union{Nothing, IndexCache}
    """
    The hierarchical parent system before simplification.
    """
    parent::Any

    function DiscreteSystem(tag, discreteEqs, iv, dvs, ps, tspan, var_to_name,
            observed,
            name,
            systems, defaults, preface, connector_type, parameter_dependencies = nothing,
            metadata = nothing, gui_metadata = nothing,
            tearing_state = nothing, substitutions = nothing,
            complete = false, index_cache = nothing, parent = nothing;
            checks::Union{Bool, Int} = true)
        if checks == true || (checks & CheckComponents) > 0
            check_variables(dvs, iv)
            check_parameters(ps, iv)
        end
        if checks == true || (checks & CheckUnits) > 0
            u = __get_unit_type(dvs, ps, iv)
            check_units(u, discreteEqs)
        end
        new(tag, discreteEqs, iv, dvs, ps, tspan, var_to_name, observed, name,
            systems,
            defaults,
            preface, connector_type, parameter_dependencies, metadata, gui_metadata,
            tearing_state, substitutions, complete, index_cache, parent)
    end
end

"""
    $(TYPEDSIGNATURES)
Constructs a DiscreteSystem.
"""
function DiscreteSystem(eqs::AbstractVector{<:Equation}, iv, dvs, ps;
        observed = Num[],
        systems = DiscreteSystem[],
        tspan = nothing,
        name = nothing,
        default_u0 = Dict(),
        default_p = Dict(),
        defaults = _merge(Dict(default_u0), Dict(default_p)),
        preface = nothing,
        connector_type = nothing,
        parameter_dependencies = nothing,
        metadata = nothing,
        gui_metadata = nothing,
        kwargs...)
    name === nothing &&
        throw(ArgumentError("The `name` keyword must be provided. Please consider using the `@named` macro"))
    iv′ = value(iv)
    dvs′ = value.(dvs)
    ps′ = value.(ps)
    if any(hasderiv, eqs) || any(hashold, eqs) || any(hassample, eqs) || any(hasdiff, eqs)
        error("Equations in a `DiscreteSystem` can only have `Shift` operators.")
    end
    if !(isempty(default_u0) && isempty(default_p))
        Base.depwarn(
            "`default_u0` and `default_p` are deprecated. Use `defaults` instead.",
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
        eqs, iv′, dvs′, ps′, tspan, var_to_name, observed, name, systems,
        defaults, preface, connector_type, parameter_dependencies, metadata, gui_metadata, kwargs...)
end

function DiscreteSystem(eqs, iv; kwargs...)
    eqs = collect(eqs)
    diffvars = OrderedSet()
    allunknowns = OrderedSet()
    ps = OrderedSet()
    iv = value(iv)
    for eq in eqs
        collect_vars!(allunknowns, ps, eq.lhs, iv; op = Shift)
        collect_vars!(allunknowns, ps, eq.rhs, iv; op = Shift)
        if iscall(eq.lhs) && operation(eq.lhs) isa Shift
            isequal(iv, operation(eq.lhs).t) ||
                throw(ArgumentError("A DiscreteSystem can only have one independent variable."))
            eq.lhs in diffvars &&
                throw(ArgumentError("The shift variable $(eq.lhs) is not unique in the system of equations."))
            push!(diffvars, eq.lhs)
        end
    end
    new_ps = OrderedSet()
    for p in ps
        if iscall(p) && operation(p) === getindex
            par = arguments(p)[begin]
            if Symbolics.shape(Symbolics.unwrap(par)) !== Symbolics.Unknown() &&
               all(par[i] in ps for i in eachindex(par))
                push!(new_ps, par)
            else
                push!(new_ps, p)
            end
        else
            push!(new_ps, p)
        end
    end
    return DiscreteSystem(eqs, iv,
        collect(allunknowns), collect(new_ps); kwargs...)
end

function flatten(sys::DiscreteSystem, noeqs = false)
    systems = get_systems(sys)
    if isempty(systems)
        return sys
    else
        return DiscreteSystem(noeqs ? Equation[] : equations(sys),
            get_iv(sys),
            unknowns(sys),
            parameters(sys),
            observed = observed(sys),
            defaults = defaults(sys),
            name = nameof(sys),
            checks = false)
    end
end

function generate_function(
        sys::DiscreteSystem, dvs = unknowns(sys), ps = full_parameters(sys); kwargs...)
    generate_custom_function(sys, [eq.rhs for eq in equations(sys)], dvs, ps; kwargs...)
end

function process_DiscreteProblem(constructor, sys::DiscreteSystem, u0map, parammap;
        linenumbers = true, parallel = SerialForm(),
        use_union = false,
        tofloat = !use_union,
        eval_expression = false, eval_module = @__MODULE__,
        kwargs...)
    iv = get_iv(sys)
    eqs = equations(sys)
    dvs = unknowns(sys)
    ps = parameters(sys)

    trueu0map = Dict()
    for (k, v) in u0map
        k = unwrap(k)
        if !((op = operation(k)) isa Shift)
            error("Initial conditions must be for the past state of the unknowns. Instead of providing the condition for $k, provide the condition for $(Shift(iv, -1)(k)).")
        end
        trueu0map[Shift(iv, op.steps + 1)(arguments(k)[1])] = v
    end
    defs = ModelingToolkit.get_defaults(sys)
    for var in dvs
        if (op = operation(var)) isa Shift && !haskey(trueu0map, var)
            root = arguments(var)[1]
            haskey(defs, root) || error("Initial condition for $var not provided.")
            trueu0map[var] = defs[root]
        end
    end
    if has_index_cache(sys) && get_index_cache(sys) !== nothing
        u0, defs = get_u0(sys, trueu0map, parammap)
        p = MTKParameters(sys, parammap, trueu0map; eval_expression, eval_module)
    else
        u0, p, defs = get_u0_p(sys, trueu0map, parammap; tofloat, use_union)
    end

    check_eqs_u0(eqs, dvs, u0; kwargs...)

    f = constructor(sys, dvs, ps, u0;
        linenumbers = linenumbers, parallel = parallel,
        syms = Symbol.(dvs), paramsyms = Symbol.(ps),
        eval_expression = eval_expression, eval_module = eval_module,
        kwargs...)
    return f, u0, p
end

"""
    $(TYPEDSIGNATURES)
Generates an DiscreteProblem from an DiscreteSystem.
"""
function SciMLBase.DiscreteProblem(
        sys::DiscreteSystem, u0map = [], tspan = get_tspan(sys),
        parammap = SciMLBase.NullParameters();
        eval_module = @__MODULE__,
        eval_expression = false,
        use_union = false,
        kwargs...
)
    if !iscomplete(sys)
        error("A completed `DiscreteSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `DiscreteProblem`")
    end
    dvs = unknowns(sys)
    ps = parameters(sys)
    eqs = equations(sys)
    iv = get_iv(sys)

    f, u0, p = process_DiscreteProblem(
        DiscreteFunction, sys, u0map, parammap; eval_expression, eval_module)
    u0 = f(u0, p, tspan[1])
    DiscreteProblem(f, u0, tspan, p; kwargs...)
end

function SciMLBase.DiscreteFunction(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunction{true}(sys, args...; kwargs...)
end

function SciMLBase.DiscreteFunction{true}(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunction{true, SciMLBase.AutoSpecialize}(sys, args...; kwargs...)
end

function SciMLBase.DiscreteFunction{false}(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunction{false, SciMLBase.FullSpecialize}(sys, args...; kwargs...)
end
function SciMLBase.DiscreteFunction{iip, specialize}(
        sys::DiscreteSystem,
        dvs = unknowns(sys),
        ps = full_parameters(sys),
        u0 = nothing;
        version = nothing,
        p = nothing,
        t = nothing,
        eval_expression = false,
        eval_module = @__MODULE__,
        analytic = nothing,
        kwargs...) where {iip, specialize}
    if !iscomplete(sys)
        error("A completed `DiscreteSystem` is required. Call `complete` or `structural_simplify` on the system before creating a `DiscreteProblem`")
    end
    f_gen = generate_function(sys, dvs, ps; expression = Val{true},
        expression_module = eval_module, kwargs...)
    f_oop, f_iip = eval_or_rgf.(f_gen; eval_expression, eval_module)
    f(u, p, t) = f_oop(u, p, t)
    f(du, u, p, t) = f_iip(du, u, p, t)

    if specialize === SciMLBase.FunctionWrapperSpecialize && iip
        if u0 === nothing || p === nothing || t === nothing
            error("u0, p, and t must be specified for FunctionWrapperSpecialize on DiscreteFunction.")
        end
        f = SciMLBase.wrapfun_iip(f, (u0, u0, p, t))
    end

    observedfun = ObservedFunctionCache(sys)

    DiscreteFunction{iip, specialize}(f;
        sys = sys,
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

function DiscreteFunctionExpr{iip}(sys::DiscreteSystem, dvs = unknowns(sys),
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
        DiscreteFunction{$iip}($fsym)
    end
    !linenumbers ? Base.remove_linenums!(ex) : ex
end

function DiscreteFunctionExpr(sys::DiscreteSystem, args...; kwargs...)
    DiscreteFunctionExpr{true}(sys, args...; kwargs...)
end
