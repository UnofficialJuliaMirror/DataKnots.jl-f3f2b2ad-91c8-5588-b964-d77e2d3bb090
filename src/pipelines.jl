#
# Combinator algebra of vectorized data transformations.
#

import Base:
    OneTo,
    show

using Base.Cartesian


#
# Pipeline interface.
#

"""
    Runtime()

Runtime state for pipeline evaluation.
"""
mutable struct Runtime
end

"""
    Pipeline(op, args...)

A pipeline object represents a vectorized data transformation.

Parameter `op` is a function that performs the transformation; `args` are extra
arguments to be passed to the function.

The pipeline transforms any input vector by invoking `op` with the following
arguments:

    op(rt::Runtime, input::AbstractVector, args...)

The result of `op` must be the output vector, which should be of the same
length as the input vector.
"""
struct Pipeline
    op
    args::Vector{Any}
    sig::Signature

    Pipeline(op, args::Vector{Any}, sig::Signature) =
        new(op, args, sig)
end

let NO_SIG = Signature()

    global Pipeline

    Pipeline(op, args...) =
        Pipeline(op, collect(Any, args), NO_SIG)
end

"""
    designate(::Pipeline, ::Signature) :: Pipeline
    designate(::Pipeline, ::InputShape, ::OutputShape) :: Pipeline
    p::Pipeline |> designate(::Signature) :: Pipeline
    p::Pipeline |> designate(::InputShape, ::OutputShape) :: Pipeline

Sets the pipeline signature.
"""
function designate end

designate(p::Pipeline, sig::Signature) =
    Pipeline(p.op, p.args, sig)

designate(p::Pipeline, ishp::Union{AbstractShape,Type}, shp::Union{AbstractShape,Type}) =
    Pipeline(p.op, p.args, Signature(ishp, shp))

designate(sig::Signature) =
    p::Pipeline -> designate(p, sig)

designate(ishp::Union{AbstractShape,Type}, shp::Union{AbstractShape,Type}) =
    p::Pipeline -> designate(p, Signature(ishp, shp))

"""
    signature(::Pipeline) :: Signature

Returns the pipeline signature.
"""
signature(p::Pipeline) = p.sig

shape(p::Pipeline) = shape(p.sig)

ishape(p::Pipeline) = ishape(p.sig)

function (p::Pipeline)(input::DataKnot)
    @assert fits(shape(input), ishape(p))
    DataKnot(p(cell(input)), shape(p))
end

function (p::Pipeline)(input::AbstractVector)
    rt = Runtime()
    output = p(rt, input)
end

function (p::Pipeline)(rt::Runtime, input::AbstractVector)
    p.op(rt, input, p.args...)
end

quoteof(p::Pipeline) =
    quoteof(p.op, p.args)

show(io::IO, p::Pipeline) =
    print_expr(io, quoteof(p))

"""
    optimize(::Pipeline) :: Pipeline

Rewrites the pipeline to make it (hopefully) faster.
"""
optimize(p::Pipeline) =
    simplify(p) |> designate(p.sig)


#
# Vectorizing scalar functions.
#

"""
    lift(f) :: Pipeline

`f` is any scalar unary function.

The pipeline applies `f` to each element of the input vector.
"""
lift(f) = Pipeline(lift, f)

lift(rt::Runtime, input::AbstractVector, f) =
    f.(input)

"""
    tuple_lift(f) :: Pipeline

`f` is an n-ary function.

The pipeline applies `f` to each row of an n-tuple vector.
"""
tuple_lift(f) = Pipeline(tuple_lift, f)

function tuple_lift(rt::Runtime, input::AbstractVector, f)
    @assert input isa TupleVector
    _tuple_lift(f, length(input), columns(input)...)
end

@generated function _tuple_lift(f, len::Int, cols::AbstractVector...)
    D = length(cols)
    return quote
        I = Tuple{eltype.(cols)...}
        O = Core.Compiler.return_type(f, I)
        output = Vector{O}(undef, len)
        @inbounds for k = 1:len
            output[k] = @ncall $D f (d -> cols[d][k])
        end
        output
    end
end

"""
    block_lift(f) :: Pipeline
    block_lift(f, default) :: Pipeline

`f` is a function that expects a vector argument.

The pipeline applies `f` to each block of the input block vector.  When a block
is empty, `default` (if specified) is used as the output value.
"""
function block_lift end

block_lift(f) = Pipeline(block_lift, f)

function block_lift(rt::Runtime, input::AbstractVector, f)
    @assert input isa BlockVector
    _block_lift(f, input)
end

block_lift(f, default) = Pipeline(block_lift, f, default)

function block_lift(rt::Runtime, input::AbstractVector, f, default)
    @assert input isa BlockVector
    _block_lift(f, default, input)
end

function _block_lift(f, input)
    I = Tuple{typeof(cursor(input))}
    O = Core.Compiler.return_type(f, I)
    output = Vector{O}(undef, length(input))
    @inbounds for cr in cursor(input)
        output[cr.pos] = f(cr)
    end
    output
end

function _block_lift(f, default, input)
    I = Tuple{typeof(cursor(input))}
    O = Union{Core.Compiler.return_type(f, I), typeof(default)}
    output = Vector{O}(undef, length(input))
    @inbounds for cr in cursor(input)
        output[cr.pos] = !isempty(cr) ? f(cr) : default
    end
    output
end

"""
    filler(val) :: Pipeline

This pipeline produces a vector filled with the given value.
"""
filler(val) = Pipeline(filler, val)

filler(rt::Runtime, input::AbstractVector, val) =
    fill(val, length(input))

"""
    null_filler() :: Pipeline

This pipeline produces a block vector with empty blocks.
"""
null_filler() = Pipeline(null_filler)

null_filler(rt::Runtime, input::AbstractVector) =
    BlockVector(fill(1, length(input)+1), Union{}[], x0to1)

"""
    block_filler(block::AbstractVector, card::Cardinality) :: Pipeline

This pipeline produces a block vector filled with the given block.
"""
block_filler(block, card::Cardinality=x0toN) = Pipeline(block_filler, block, card)

function block_filler(rt::Runtime, input::AbstractVector, block::AbstractVector, card::Cardinality)
    if isempty(input)
        return BlockVector(:, block[[]], card)
    elseif length(input) == 1
        return BlockVector([1, length(block)+1], block, card)
    else
        len = length(input)
        sz = length(block)
        perm = Vector{Int}(undef, len*sz)
        for k in eachindex(input)
            copyto!(perm, 1 + sz * (k - 1), 1:sz)
        end
        return BlockVector(1:sz:(len*sz+1), block[perm], card)
    end
end


#
# Converting regular vectors to columnar vectors.
#

"""
    adapt_missing() :: Pipeline

This pipeline transforms a vector that contains `missing` elements to a block
vector with `missing` elements replaced by empty blocks.
"""
adapt_missing() = Pipeline(adapt_missing)

function adapt_missing(rt::Runtime, input::AbstractVector)
    if !(Missing <: eltype(input))
        return BlockVector(:, input, x0to1)
    end
    sz = 0
    for elt in input
        if elt !== missing
            sz += 1
        end
    end
    O = Base.nonmissingtype(eltype(input))
    if sz == length(input)
        return BlockVector(:, collect(O, input), x0to1)
    end
    offs = Vector{Int}(undef, length(input)+1)
    elts = Vector{O}(undef, sz)
    @inbounds offs[1] = top = 1
    @inbounds for k in eachindex(input)
        elt = input[k]
        if elt !== missing
            elts[top] = elt
            top += 1
        end
        offs[k+1] = top
    end
    return BlockVector(offs, elts, x0to1)
end

"""
    adapt_vector() :: Pipeline

This pipeline transforms a vector with vector elements to a block vector.
"""
adapt_vector() = Pipeline(adapt_vector)

function adapt_vector(rt::Runtime, input::AbstractVector)
    @assert eltype(input) <: AbstractVector
    sz = 0
    for v in input
        sz += length(v)
    end
    O = eltype(eltype(input))
    offs = Vector{Int}(undef, length(input)+1)
    elts = Vector{O}(undef, sz)
    @inbounds offs[1] = top = 1
    @inbounds for k in eachindex(input)
        v = input[k]
        copyto!(elts, top, v)
        top += length(v)
        offs[k+1] = top
    end
    return BlockVector(offs, elts, x0toN)
end

"""
    adapt_tuple() :: Pipeline

This pipeline transforms a vector of tuples to a tuple vector.
"""
adapt_tuple() = Pipeline(adapt_tuple)

function adapt_tuple(rt::Runtime, input::AbstractVector)
    @assert eltype(input) <: Union{Tuple,NamedTuple}
    lbls = Symbol[]
    I = eltype(input)
    if typeof(I) == DataType && I <: NamedTuple
        lbls = collect(Symbol, I.parameters[1])
        I = I.parameters[2]
    end
    cols = _adapt_tuple(input, Val(Tuple{I.parameters...}))
    TupleVector(lbls, length(input), cols)
end

@generated function _adapt_tuple(input, vty)
    Is = (vty.parameters[1].parameters...,)
    D = length(Is)
    return quote
        len = length(input)
        @nexprs $D j -> col_j = Vector{$Is[j]}(undef, len)
        @inbounds for k in eachindex(input)
            t = input[k]
            @nexprs $D j -> col_j[k] = t[j]
        end
        @nref $D AbstractVector j -> col_j
    end
end


#
# Identity and composition.
#

"""
    pass() :: Pipeline

This pipeline returns its input unchanged.
"""
pass() = Pipeline(pass)

pass(rt::Runtime, input::AbstractVector) =
    input

"""
    chain_of(p₁::Pipeline, p₂::Pipeline … pₙ::Pipeline) :: Pipeline

This pipeline sequentially applies `p₁`, `p₂` … `pₙ`.
"""
function chain_of end

chain_of() = pass()

chain_of(p) = p

function chain_of(ps...)
    ps′ = filter(p -> !(p isa Pipeline && p.op == pass), collect(ps))
    isempty(ps′) ? pass() : length(ps′) == 1 ? ps′[1] : chain_of(ps′)
end

chain_of(ps::Vector) =
    Pipeline(chain_of, ps)

quoteof(::typeof(chain_of), args::Vector{Any}) =
    if length(args) == 1 && args[1] isa Vector
        Expr(:call, chain_of, quoteof.(args[1])...)
    else
        Expr(:call, chain_of, quoteof.(args)...)
    end

function chain_of(rt::Runtime, input::AbstractVector, ps)
    output = input
    for p in ps
        output = p(rt, output)
    end
    output
end


#
# Operations on tuple vectors.
#

"""
    tuple_of(p₁::Pipeline, p₂::Pipeline … pₙ::Pipeline) :: Pipeline

This pipeline produces an n-tuple vector, whose columns are generated by
applying `p₁`, `p₂` … `pₙ` to the input vector.
"""
tuple_of(ps...) =
    tuple_of(Symbol[], collect(ps))

tuple_of(lps::Pair{Symbol}...) =
    tuple_of(collect(Symbol, first.(lps)), collect(last.(lps)))

tuple_of(lbls::Vector{Symbol}, ps::Vector) = Pipeline(tuple_of, lbls, ps)

quoteof(::typeof(tuple_of), args::Vector{Any}) =
    if length(args) == 2 && args[1] isa Vector{Symbol} && args[2] isa Vector
        if isempty(args[1])
            Expr(:call, tuple_of, quoteof.(args[2])...)
        else
            Expr(:call, tuple_of, quoteof.(args[1] .=> args[2])...)
        end
    else
        Expr(:call, tuple_of, quoteof.(args)...)
    end

function tuple_of(rt::Runtime, input::AbstractVector, lbls, ps)
    len = length(input)
    cols = AbstractVector[p(rt, input) for p in ps]
    TupleVector(lbls, len, cols)
end

"""
    column(lbl::Union{Int,Symbol}) :: Pipeline

This pipeline extracts the specified column of a tuple vector.
"""
column(lbl::Union{Int,Symbol}) = Pipeline(column, lbl)

function column(rt::Runtime, input::AbstractVector, lbl)
    @assert input isa TupleVector
    j = locate(input, lbl)
    column(input, j)
end

"""
    with_column(lbl::Union{Int,Symbol}, p::Pipeline) :: Pipeline

This pipeline transforms a tuple vector by applying `p` to the specified
column.
"""
with_column(lbl::Union{Int,Symbol}, p) = Pipeline(with_column, lbl, p)

function with_column(rt::Runtime, input::AbstractVector, lbl, p)
    @assert input isa TupleVector
    j = locate(input, lbl)
    cols′ = copy(columns(input))
    cols′[j] = p(rt, cols′[j])
    TupleVector(labels(input), length(input), cols′)
end


#
# Operations on block vectors.
#

"""
    wrap() :: Pipeline

This pipeline produces a block vector with one-element blocks wrapping the
values of the input vector.
"""
wrap() = Pipeline(wrap)

wrap(rt::Runtime, input::AbstractVector) =
    BlockVector(:, input, x1to1)


"""
    with_elements(p::Pipeline) :: Pipeline

This pipeline transforms a block vector by applying `p` to its vector of
elements.
"""
with_elements(p) = Pipeline(with_elements, p)

function with_elements(rt::Runtime, input::AbstractVector, p)
    @assert input isa BlockVector
    BlockVector(offsets(input), p(rt, elements(input)), cardinality(input))
end

"""
    flatten() :: Pipeline

This pipeline flattens a nested block vector.
"""
flatten() = Pipeline(flatten)

function flatten(rt::Runtime, input::AbstractVector)
    @assert input isa BlockVector && elements(input) isa BlockVector
    offs = offsets(input)
    nested = elements(input)
    nested_offs = offsets(nested)
    elts = elements(nested)
    card = cardinality(input)|cardinality(nested)
    BlockVector(_flatten(offs, nested_offs), elts, card)
end

_flatten(offs1::AbstractVector{Int}, offs2::AbstractVector{Int}) =
    Int[offs2[off] for off in offs1]

_flatten(offs1::OneTo{Int}, offs2::OneTo{Int}) = offs1

_flatten(offs1::OneTo{Int}, offs2::AbstractVector{Int}) = offs2

_flatten(offs1::AbstractVector{Int}, offs2::OneTo{Int}) = offs1

"""
    distribute(lbl::Union{Int,Symbol}) :: Pipeline

This pipeline transforms a tuple vector with a column of blocks to a block
vector with tuple elements.
"""
distribute(lbl) = Pipeline(distribute, lbl)

function distribute(rt::Runtime, input::AbstractVector, lbl)
    @assert input isa TupleVector && column(input, lbl) isa BlockVector
    j = locate(input, lbl)
    _distribute(column(input, j), input, j)
end

function _distribute(col::BlockVector, tv::TupleVector, j)
    lbls = labels(tv)
    cols′ = copy(columns(tv))
    len = length(col)
    card = cardinality(col)
    offs = offsets(col)
    col′ = elements(col)
    if offs isa OneTo{Int}
        cols′[j] = col′
        return BlockVector{card}(offs, TupleVector(lbls, len, cols′))
    end
    len′ = length(col′)
    perm = Vector{Int}(undef, len′)
    l = r = 1
    @inbounds for k = 1:len
        l = r
        r = offs[k+1]
        for n = l:r-1
            perm[n] = k
        end
    end
    for i in eachindex(cols′)
        cols′[i] =
            if i == j
                col′
            else
                cols′[i][perm]
            end
    end
    return BlockVector{card}(offs, TupleVector(lbls, len′, cols′))
end

"""
    distribute_all() :: Pipeline

This pipeline transforms a tuple vector with block columns to a block vector
with tuple elements.
"""
distribute_all() = Pipeline(distribute_all)

function distribute_all(rt::Runtime, input::AbstractVector)
    @assert input isa TupleVector && all(col isa BlockVector for col in columns(input))
    cols = columns(input)
    _distribute_all(labels(input), length(input), cols...)
end

@generated function _distribute_all(lbls::Vector{Symbol}, len::Int, cols::BlockVector...)
    D = length(cols)
    CARD = |(x1to1, cardinality.(cols)...)
    return quote
        @nextract $D offs (d -> offsets(cols[d]))
        @nextract $D elts (d -> elements(cols[d]))
        if @nall $D (d -> offs_d isa OneTo{Int})
            return BlockVector{$CARD}(:, TupleVector(lbls, len, AbstractVector[(@ntuple $D elts)...]))
        end
        len′ = 0
        regular = true
        @inbounds for k = 1:len
            sz = @ncall $D (*) (d -> (offs_d[k+1] - offs_d[k]))
            len′ += sz
            regular = regular && sz == 1
        end
        if regular
            return BlockVector{$CARD}(:, TupleVector(lbls, len, AbstractVector[(@ntuple $D elts)...]))
        end
        offs′ = Vector{Int}(undef, len+1)
        @nextract $D perm (d -> Vector{Int}(undef, len′))
        @inbounds offs′[1] = top = 1
        @inbounds for k = 1:len
            @nloops $D n (d -> offs_{$D-d+1}[k]:offs_{$D-d+1}[k+1]-1) begin
                @nexprs $D (d -> perm_{$D-d+1}[top] = n_d)
                top += 1
            end
            offs′[k+1] = top
        end
        cols′ = @nref $D AbstractVector (d -> elts_d[perm_d])
        return BlockVector{$CARD}(offs′, TupleVector(lbls, len′, cols′))
    end
end

"""
    block_length() :: Pipeline

This pipeline converts a block vector to a vector of block lengths.
"""
block_length() = Pipeline(block_length)

function block_length(rt::Runtime, input::AbstractVector)
    @assert input isa BlockVector
    _block_length(offsets(input))
end

_block_length(offs::OneTo{Int}) =
    fill(1, length(offs)-1)

function _block_length(offs::AbstractVector{Int})
    len = length(offs) - 1
    output = Vector{Int}(undef, len)
    @inbounds for k = 1:len
        output[k] = offs[k+1] - offs[k]
    end
    output
end

"""
    block_any() :: Pipeline

This pipeline applies `any` to a block vector with `Bool` elements.
"""
block_any() = Pipeline(block_any)

function block_any(rt::Runtime, input::AbstractVector)
    @assert input isa BlockVector && eltype(elements(input)) <: Bool
    len = length(input)
    offs = offsets(input)
    elts = elements(input)
    if offs isa OneTo
        return elts
    end
    output = Vector{Bool}(undef, len)
    l = r = 1
    @inbounds for k = 1:len
        val = false
        l = r
        r = offs[k+1]
        for i = l:r-1
            if elts[i]
                val = true
                break
            end
        end
        output[k] = val
    end
    return output
end


#
# Filtering.
#

"""
    sieve() :: Pipeline

This pipeline filters a vector of pairs by the second column.  It expects a
pair vector, whose second column is a `Bool` vector, and produces a block
vector with 0- or 1-element blocks containing the elements of the first column.
"""
sieve() = Pipeline(sieve)

function sieve(rt::Runtime, input::AbstractVector)
    @assert input isa TupleVector && width(input) == 2 && eltype(column(input, 2)) <: Bool
    val_col, pred_col = columns(input)
    _sieve(val_col, pred_col)
end

function _sieve(@nospecialize(v), bv)
    len = length(bv)
    sz = count(bv)
    if sz == len
        return BlockVector(:, v, x0to1)
    elseif sz == 0
        return BlockVector(fill(1, len+1), v[[]], x0to1)
    end
    offs = Vector{Int}(undef, len+1)
    perm = Vector{Int}(undef, sz)
    @inbounds offs[1] = top = 1
    for k = 1:len
        if bv[k]
            perm[top] = k
            top += 1
        end
        offs[k+1] = top
    end
    return BlockVector(offs, v[perm], x0to1)
end


#
# Slicing.
#

"""
    slice(N::Int, rev::Bool=false) :: Pipeline

This pipeline transforms a block vector by keeping the first `N` elements of
each block.  If `rev` is true, the pipeline drops the first `N` elements of
each block.
"""
slice(N::Union{Missing,Int}, rev::Bool=false) =
    Pipeline(slice, N, rev)

function slice(rt::Runtime, input::AbstractVector, N::Missing, rev::Bool)
    @assert input isa BlockVector
    input
end

function slice(rt::Runtime, input::AbstractVector, N::Int, rev::Bool)
    @assert input isa BlockVector
    len = length(input)
    offs = offsets(input)
    elts = elements(input)
    sz = 0
    R = 1
    for k = 1:len
        L = R
        @inbounds R = offs[k+1]
        (l, r) = _slice_range(N, R-L, rev)
        sz += r - l + 1
    end
    if sz == length(elts)
        return input
    end
    offs′ = Vector{Int}(undef, len+1)
    perm = Vector{Int}(undef, sz)
    @inbounds offs′[1] = top = 1
    R = 1
    for k = 1:len
        L = R
        @inbounds R = offs[k+1]
        (l, r) = _slice_range(N, R-L, rev)
        for j = (L + l - 1):(L + r - 1)
            perm[top] = j
            top += 1
        end
        offs′[k+1] = top
    end
    elts′ = elts[perm]
    card = cardinality(input)|x0to1
    return BlockVector(offs′, elts′, card)
end

"""
    slice(rev::Bool=false) :: Pipeline

This pipeline takes a pair vector of blocks and integers, and returns the first
column with blocks restricted by the second column.
"""
slice(rev::Bool=false) =
    Pipeline(slice, rev)

function slice(rt::Runtime, input::AbstractVector, rev::Bool)
    @assert input isa TupleVector
    cols = columns(input)
    @assert length(cols) == 2
    vals, Ns = cols
    @assert vals isa BlockVector
    @assert eltype(Ns) <: Union{Missing,Int}
    _slice(elements(vals), offsets(vals), cardinality(vals), Ns, rev)
end

function _slice(@nospecialize(elts), offs, card, Ns, rev)
    card′ = card|x0to1
    len = length(Ns)
    R = 1
    sz = 0
    for k = 1:len
        L = R
        @inbounds N = Ns[k]
        @inbounds R = offs[k+1]
        (l, r) = _slice_range(N, R-L, rev)
        sz += r - l + 1
    end
    if sz == length(elts)
        return BlockVector(offs, elts, card′)
    end
    offs′ = Vector{Int}(undef, len+1)
    perm = Vector{Int}(undef, sz)
    @inbounds offs′[1] = top = 1
    R = 1
    for k = 1:len
        L = R
        @inbounds N = Ns[k]
        @inbounds R = offs[k+1]
        (l, r) = _slice_range(N, R-L, rev)
        for j = (L + l - 1):(L + r - 1)
            perm[top] = j
            top += 1
        end
        offs′[k+1] = top
    end
    elts′ = elts[perm]
    return BlockVector(offs′, elts′, card′)
end

@inline _slice_range(n::Int, l::Int, rev::Bool) =
    if !rev
        (1, n >= 0 ? min(l, n) : max(0, l + n))
    else
        (n >= 0 ? min(l + 1, n + 1) : max(1, l + n + 1), l)
    end

@inline _slice_range(::Missing, l::Int, ::Bool) =
    (1, l)


#
# Optimizing a pipeline expression.
#

function simplify(p::Pipeline)
    ps = simplify_chain(p)
    if isempty(ps)
        return pass()
    elseif length(ps) == 1
        return ps[1]
    else
        return chain_of(ps)
    end
end

simplify(ps::Vector{Pipeline}) =
    simplify.(ps)

simplify(other) = other

function simplify_chain(p::Pipeline)
    if p.op == pass
        return Pipeline[]
    elseif p.op == with_column && p.args[2].op == pass
        return Pipeline[]
    elseif p.op == with_elements && p.args[1].op == pass
        return Pipeline[]
    elseif p.op == chain_of
        return simplify_block(vcat(simplify_chain.(p.args[1])...))
    else
        return [Pipeline(p.op, simplify.(p.args)...)]
    end
end

function simplify_block(ps)
    simplified = true
    while simplified
        simplified = false
        ps′ = Pipeline[]
        k = 1
        while k <= length(ps)
            if ps[k].op == with_column && ps[k].args[2].op == pass
                simplified = true
                k += 1
            elseif ps[k].op == with_elements && ps[k].args[1].op == pass
                simplified = true
                k += 1
            elseif k <= length(ps)-1 && ps[k].op == with_elements && ps[k].args[1].op == wrap && ps[k+1].op == flatten
                simplified = true
                k += 2
            elseif k <= length(ps)-2 && ps[k].op == wrap && ps[k+1].op == with_elements && ps[k+2].op == flatten
                simplified = true
                p = ps[k+1].args[1]
                if p.op == pass
                elseif p.op == chain_of
                    append!(ps′, p.args[1])
                else
                    push!(ps′, p)
                end
                k += 3
            elseif k <= length(ps)-2 && ps[k].op == with_elements && ps[k+1].op == flatten && ps[k+2].op == with_elements
                simplified = true
                p = with_elements(simplify(chain_of(ps[k].args[1], ps[k+2])))
                push!(ps′, p)
                push!(ps′, ps[k+1])
                k += 3
            elseif k <= length(ps)-1 && ps[k].op == tuple_of && ps[k+1].op == column && ps[k+1].args[1] isa Int
                simplified = true
                p = ps[k].args[2][ps[k+1].args[1]]
                if p.op == pass
                elseif p.op == chain_of
                    append!(ps′, p.args[1])
                else
                    push!(ps′, p)
                end
                k += 2
            elseif k <= length(ps)-1 && ps[k].op == with_elements && ps[k+1].op == with_elements
                simplified = true
                p = with_elements(simplify(chain_of(ps[k].args[1], ps[k+1].args[1])))
                push!(ps′, p)
                k += 2
            else
                push!(ps′, ps[k])
                k += 1
            end
        end
        ps = ps′
    end
    ps
end
