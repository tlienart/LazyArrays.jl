module LazyLinearAlgebra
using Base
using Base.Broadcast
using LinearAlgebra
using LinearAlgebra.BLAS

import Base: ReinterpretArray, ReshapedArray, AbstractCartesianIndex, Slice,
             RangeIndex, BroadcastStyle, copyto!, length, broadcastable, axes,
             getindex, eltype, tail
import Base.Broadcast: DefaultArrayStyle, Broadcasted
import LinearAlgebra.BLAS: BlasFloat, BlasReal, BlasComplex
export Mul

include("memorylayout.jl")

struct MatrixMulVectorStyle{StyleA, StyleX} <: BroadcastStyle end

struct Mul{T, StyleA, StyleX, AType, XType}
    style_A::StyleA
    style_x::StyleX
    A::AType
    x::XType
end


Mul(styleA, stylex, A, x) =
    Mul{Base.promote_op(*, eltype(A), eltype(x)),
        typeof(styleA), typeof(stylex),
        typeof(A), typeof(x)}(styleA, stylex, A, x)
Mul(A, x) = Mul(MemoryLayout(A), MemoryLayout(x), A, x)

eltype(::Mul{T}) where T = T

const MatrixMulVector{T, styleA, styleX, AType<:AbstractMatrix, XType<:AbstractVector} =
    Mul{T, styleA, styleX, AType, XType}
const BMatVec{T, styleA, styleB} =
    Broadcasted{<:MatrixMulVectorStyle{styleA,styleB},
                Tuple{Base.OneTo{Int}}, typeof(identity),
                <:Tuple{<:MatrixMulVector{T}}}
const BConstMatVec{T,styleA,styleB} =
    Broadcasted{<:MatrixMulVectorStyle{styleA,styleB},
                    Tuple{Base.OneTo{Int}}, typeof(*),
                    <:Tuple{T,<:MatrixMulVector{T}}}
const BMatVecPlusVec{T,styleA,styleB} =
    Broadcasted{<:MatrixMulVectorStyle{styleA, styleB},
                Tuple{Base.OneTo{Int}}, typeof(+),
                <:Tuple{<:MatrixMulVector{T},<:Vector{T}}}
const BMatVecPlusConstVec{T,styleA,styleB} =
    Broadcasted{<:MatrixMulVectorStyle{styleA,styleB},
                Tuple{Base.OneTo{Int}}, typeof(+),
                <:Tuple{<:MatrixMulVector{T},
                        Broadcasted{DefaultArrayStyle{1},Nothing,typeof(*),Tuple{T,Vector{T}}}}}
const BConstMatVecPlusConstVec{T, styleA, styleB} =
    Broadcasted{<:MatrixMulVectorStyle{styleA,styleB},
                Tuple{Base.OneTo{Int}}, typeof(+),
                <:Tuple{Broadcasted{<:MatrixMulVectorStyle{styleA,styleB},
                                    Nothing, typeof(*), <:Tuple{T,<:MatrixMulVector{T}}},
                        Broadcasted{DefaultArrayStyle{1},Nothing,typeof(*),Tuple{T,Vector{T}}}}}

length(M::MatrixMulVector) = size(M.A,1)
axes(M::MatrixMulVector) = (Base.OneTo(length(M)),)
broadcastable(M::MatrixMulVector) = M

function getindex(M::MatrixMulVector{T}, k::Int) where T
    ret = zero(T)
    for j = 1:size(M.A,2)
        ret += M.A[k,j] * M.x[j]
    end
    ret
end

getindex(M::MatrixMulVector, k::CartesianIndex{1}) = M[convert(Int, k)]

BroadcastStyle(::Type{<:MatrixMulVector{<:Any,StyleA,StyleX}}) where {StyleA,StyleX} = MatrixMulVectorStyle{StyleA,StyleX}()
BroadcastStyle(M::MatrixMulVectorStyle, ::DefaultArrayStyle) = M
BroadcastStyle(::DefaultArrayStyle, M::MatrixMulVectorStyle) = M
similar(M::Broadcasted{<:MatrixMulVectorStyle}, ::Type{ElType}) where ElType = Vector{Eltype}(length(M.args[1]))

copyto!(dest::AbstractVector, bc::Broadcasted{<:MatrixMulVectorStyle}) =
    _copyto!(MemoryLayout(dest), dest, bc)

# Use default
_copyto!(_, dest, bc) = copyto!(dest, Broadcasted{Nothing}(bc.f, bc.args, bc.axes))

# Matrix * Vector

function _copyto!(::AbstractStridedLayout, dest::AbstractVector,
         bc::BMatVec{T, <:AbstractColumnMajor, <:AbstractStridedLayout}) where T<: BlasFloat
    M = bc.args[1]
    dest .= one(T) .* M .+ zero(T) .* dest
end


function _copyto!(::AbstractStridedLayout, dest::AbstractVector{T},
         bc::BConstMatVec{T, <:AbstractColumnMajor,<:AbstractStridedLayout}) where T<: BlasFloat
    α,M = bc.args
    dest .= α .* M .+ zero(T) .* dest
end


function _copyto!(::AbstractStridedLayout, dest::AbstractVector,
         bc::BMatVecPlusVec{T,<:AbstractColumnMajor,<:AbstractStridedLayout}) where T<: BlasFloat
    M,c = bc.args
    dest .= one(T) .* M .+ one(T) .* dest
end

function _copyto!(::AbstractStridedLayout, dest::AbstractVector,
         bc::BMatVecPlusConstVec{T,<:AbstractColumnMajor,<:AbstractStridedLayout}) where T<: BlasFloat
    M,βc = bc.args
    β,c = βc.args
    dest .= one(T) .* M .+  β .* dest
end


function _copyto!(::AbstractStridedLayout, dest::AbstractVector,
         bc::BConstMatVecPlusConstVec{T,<:AbstractColumnMajor,<:AbstractStridedLayout}) where T<: BlasFloat
    αM,βc = bc.args
    α,M = αM.args
    A,x = M.A, M.x
    β,c = βc.args
    x ≡ dest && (x = copy(x))
    c ≡ dest || copyto!(dest, c)
    BLAS.gemv!('N', α, A, x, β, dest)
end

# AdjTrans

function _copyto!(::AbstractStridedLayout, dest::AbstractVector,
         bc::BConstMatVecPlusConstVec{T,<:AbstractRowMajor,<:AbstractStridedLayout}) where T<: BlasReal
    αM,βc = bc.args
    α,M = αM.args
    A,x = M.A, M.x
    β,c = βc.args
    x ≡ dest && (x = copy(x))
    c ≡ dest || copyto!(dest, c)
    BLAS.gemv!('T', α, transpose(A), x, β, dest)
end

function _copyto!(::AbstractStridedLayout, dest::AbstractVector,
         bc::BConstMatVecPlusConstVec{T,<:AbstractRowMajor,<:AbstractStridedLayout}) where T<: BlasComplex
    αM,βc = bc.args
    α,M = αM.args
    A,x = M.A, M.x
    β,c = βc.args
    x ≡ dest && (x = copy(x))
    c ≡ dest || copyto!(dest, c)
    BLAS.gemv!('C', α, A', x, β, dest)
end


end # module
