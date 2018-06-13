#
# Type system.
#

module Shapes

export
    OPT,
    PLU,
    REG,
    AbstractShape,
    AnyShape,
    BlockShape,
    Cardinality,
    ClassShape,
    ClosedShape,
    DecoratedShape,
    IndexShape,
    InputMode,
    InputShape,
    JSONShape,
    NativeShape,
    NoneShape,
    OutputMode,
    OutputShape,
    RecordShape,
    ShadowShape,
    Signature,
    TupleShape,
    XMLShape,
    bound,
    cardinality,
    class,
    decorate,
    decoration,
    denominalize,
    domain,
    fits,
    ibound,
    idomain,
    imode,
    isclosed,
    isframed,
    isfree,
    ishape,
    isoptional,
    isplural,
    isregular,
    mode,
    rebind,
    shape,
    signature,
    slots,
    syntax,
    unbind,
    undecorate

import Base:
    IndexStyle,
    OneTo,
    convert,
    getindex,
    eltype,
    size,
    show,
    summary,
    &, |, ~

using ..Layouts
import ..Layouts: syntax

include("sorteddict.jl")
include("bound.jl")
include("cardinality.jl")
include("shape.jl")
include("signature.jl")
include("json.jl")
include("xml.jl")

end
