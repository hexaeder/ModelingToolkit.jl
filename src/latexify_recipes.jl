prettify_expr(expr) = expr
prettify_expr(f::Function) = nameof(f)
prettify_expr(expr::Expr) = Expr(expr.head, prettify_expr.(expr.args)...)

@latexrecipe function f(eqs::Vector{ModelingToolkit.Equation})
    # Set default option values.
    env --> :align
    cdot --> false

    # Convert both the left- and right-hand sides to expressions of basic types
    # that latexify can deal with

    rhs = getfield.(eqs, :rhs)
    rhs = prettify_expr.(toexpr.(rhs))
    rhs = [postwalk(x -> x isa Expr && length(x.args) == 1 ? x.args[1] : x, eq) for eq in rhs]
    rhs = [postwalk(x -> x isa Expr && x.args[1] == :derivative && length(x.args[2].args) == 2 ? :($(Symbol(:d, x.args[2]))/($(Symbol(:d, x.args[2].args[2])))) : x, eq) for eq in rhs]
    rhs = [postwalk(x -> x isa Expr && x.args[1] == :derivative ? "\\frac{d\\left($(Latexify.latexraw(x.args[2]))\\right)}{d$(Latexify.latexraw(x.args[3]))}" : x, eq) for eq in rhs]

    lhs = getfield.(eqs, :lhs)
    lhs = prettify_expr.(toexpr.(lhs))
    lhs = [postwalk(x -> x isa Expr && length(x.args) == 1 ? x.args[1] : x, eq) for eq in lhs]
    lhs = [postwalk(x -> x isa Expr && x.args[1] == :derivative && length(x.args[2].args) == 2 ? :($(Symbol(:d, x.args[2]))/($(Symbol(:d, x.args[2].args[2])))) : x, eq) for eq in lhs]
    lhs = [postwalk(x -> x isa Expr && x.args[1] == :derivative ? "\\frac{d\\left($(Latexify.latexraw(x.args[2]))\\right)}{d$(Latexify.latexraw(x.args[3]))}" : x, eq) for eq in lhs]

    return lhs, rhs
end

@latexrecipe function f(sys::ModelingToolkit.AbstractSystem)
    return latexify(equations(sys))
end
