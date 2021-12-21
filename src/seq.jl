# This file is a part of SimilaritySearch.jl

import Base: push!

export ExhaustiveSearch, search

"""
    ExhaustiveSearch(dist::SemiMetric, db::AbstractVector)

Solves queries evaluating `dist` for the query and all elements in the dataset
"""
struct ExhaustiveSearch{DistanceType<:SemiMetric,DataType<:AbstractDatabase} <: AbstractSearchContext
    dist::DistanceType
    db::DataType
end

ExhaustiveSearch(dist::SemiMetric, db::AbstractVector) = ExhaustiveSearch(dist, convert(AbstractDatabase, db))
ExhaustiveSearch(dist::SemiMetric, db::Matrix) = ExhaustiveSearch(dist, convert(AbstractDatabase, db))
function ExhaustiveSearch(; dist=SqL2Distance(), db=VectorDatabase{Float32}())
    ExhaustiveSearch(dist, db)
end


Base.copy(seq::ExhaustiveSearch; dist=seq.dist, db=seq.db) = ExhaustiveSearch(dist, db)

"""
    search(seq::ExhaustiveSearch, q, res::AbstractKnnResult)

Solves the query evaluating all items in the given query.
"""
function search(seq::ExhaustiveSearch, q, res::AbstractKnnResult)
    st = initialstate(res)
    @inbounds for i in eachindex(seq)
        d = evaluate(seq.dist, seq[i], q)
        st = push!(res, st, i, d)
    end

    (res=res, st=st, cost=length(seq))
end

function Base.push!(seq::ExhaustiveSearch, u)
    push!(seq.db, u)
end