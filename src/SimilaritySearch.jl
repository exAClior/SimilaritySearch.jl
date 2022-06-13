# This file is a part of SimilaritySearch.jl

module SimilaritySearch
abstract type AbstractSearchContext end

using Parameters
using Polyester

import Base: push!, append!
export AbstractSearchContext, SemiMetric, evaluate, search, searchbatch, getknnresult
include("distances/Distances.jl")

include("db.jl")
include("knnresult.jl")
@inline Base.length(searchctx::AbstractSearchContext) = length(searchctx.db)
@inline Base.getindex(searchctx::AbstractSearchContext, i::Integer) = searchctx.db[i]
@inline Base.eachindex(searchctx::AbstractSearchContext) = 1:length(searchctx)
@inline Base.eltype(searchctx::AbstractSearchContext) = eltype(searchctx.db)
include("perf.jl")
include("sequential-exhaustive.jl")
include("parallel-exhaustive.jl")
include("opt.jl")
include("searchgraph/SearchGraph.jl")
include("allknn.jl")
include("neardup.jl")
include("closestpair.jl")

const GlobalKnnResult = [KnnResult(32)]   # see __init__ function at the end of this file

"""
    getknnresult(k::Integer, pools=nothing) -> KnnResult

Generic function to obtain a shared result set for the same thread and avoid memory allocations.
This function should be specialized for indexes and pools that use shared results or threads in some special way.
"""
@inline function getknnresult(k::Integer, pools=nothing)
    res = @inbounds GlobalKnnResult[Threads.threadid()]
    reuse!(res, k)
end

"""
    searchbatch(index, Q, k::Integer; minbatch=0, pools=GlobalKnnResult) -> indices, distances

Searches a batch of queries in the given index (searches for k neighbors).

# Arguments
- `index`: The search structure
- `Q`: The set of queries
- `k`: The number of neighbors to retrieve

# Keyword arguments
- `minbatch` specifies how many queries are solved per thread.
  - Integers ``1 ≤ minbatch ≤ |Q|`` are valid values
  - Set `minbatch=0` to compute a default number based on the number of available cores.
  - Set `minbatch=-1` to avoid parallelism.
- `pools` relevant for special datasets or distance functions. 
    In most case uses the default is enought, but different pools should be used when indexes use other indexes internally to solve queries.
    It should be an array of `Threads.nthreads()` preallocated `KnnResult` objects used to reduce memory allocations.
Note: The i-th column in indices and distances correspond to the i-th query in `Q`
Note: The final indices at each column can be `0` if the search process was unable to retrieve `k` neighbors.
"""
function searchbatch(index, Q, k::Integer; minbatch=0, pools=getpools(index))
    m = length(Q)
    I = zeros(Int32, k, m)
    D = Matrix{Float32}(undef, k, m)
    searchbatch(index, Q, I, D; minbatch, pools)
end

"""
    getminbatch(minbatch, n)

Used by functions that use parallelism based on `Polyester.jl` minibatches specify how many queries (or something else) are solved per thread whenever
the thread is used (in minibatches). 

# Arguments
- `minbatch`
  - Integers ``1 ≤ minbatch ≤ n`` are valid values (where n is the number of objects to process, i.e., queries)
  - Defaults to 0 which computes a default number based on the number of available cores.
  - Set `minbatch=-1` to avoid parallelism.

"""
function getminbatch(minbatch, n)
    minbatch == 0 ? min(4, ceil(Int, 1/16 * n / Threads.nthreads())) : ceil(Int, minbatch)
end

"""
    searchbatch(index, Q, I::AbstractMatrix{Int32}, D::AbstractMatrix{Float32}; minbatch=0, pools=getpools(index)) -> indices, distances

Searches a batch of queries in the given index and `I` and `D` as output (searches for `k=size(I, 1)`)

# Arguments
- `index`: The search structure
- `Q`: The set of queries
- `k`: The number of neighbors to retrieve

# Keyword arguments
- `minbatch`: Minimum number of queries solved per each thread, see [`getminbatch`](@ref)
- `pools`: relevant for special datasets or distance functions. 
    In most case uses the default is enought, but different pools should be used when indexes use other indexes internally to solve queries.
    It should be an array of `Threads.nthreads()` preallocated `KnnResult` objects used to reduce memory allocations.

"""
function searchbatch(index, Q, I::AbstractMatrix{Int32}, D::AbstractMatrix{Float32}; minbatch=0, pools=getpools(index))
    k = size(I, 1)
    minbatch = getminbatch(minbatch, length(Q))

    if minbatch > 0
        @batch minbatch=minbatch per=thread for i in eachindex(Q)
            res, _ = search(index, Q[i], getknnresult(k, pools); pools=pools)
            k_ = length(res)
            @inbounds I[1:k_, i] .= idview(res)
            @inbounds D[1:k_, i] .= distview(res)
        end
    else
        @inbounds for i in eachindex(Q)
            res, _ = search(index, Q[i], getknnresult(k, pools); pools)
            k_ = length(res)
            I[1:k_, i] .= res.id
            D[1:k_, i] .= res.dist
        end
    end

    I, D
end

"""
    searchbatch(index, Q, KNN::AbstractVector{KnnResult}; minbatch=0, pools=getpools(index)) -> indices, distances

Searches a batch of queries in the given index using an array of KnnResult's; each KnnResult object can specify different `k` values.

# Arguments
- `minbatch`: Minimum number of queries solved per each thread, see [`getminbatch`](@ref)
- `pools`: relevant for special datasets or distance functions. 
    In most case uses the default is enought, but different pools should be used when indexes use other indexes internally to solve queries.
    It should be an array of `Threads.nthreads()` preallocated `KnnResult` objects used to reduce memory allocations.

"""
function searchbatch(index, Q, KNN::AbstractVector{<:KnnResult}; minbatch=0, pools=getpools(index))
    minbatch = getminbatch(minbatch, length(Q))

    if minbatch > 0
        @batch minbatch=minbatch per=thread for i in eachindex(Q)
            @inbounds search(index, Q[i], KNN[i]; pools=pools)
        end
    else
        @inbounds for i in eachindex(Q)
            search(index, Q[i], KNN[i]; pools)
        end
    end

    KNN
end

function __init__()
    __init__visitedvertices()
    __init__beamsearch()
    __init__neighborhood()

    for _ in 2:Threads.nthreads()
        push!(GlobalKnnResult, KnnResult(32))
    end
end

# precompile as the final step of the module definition:


#=
if ccall(:jl_generating_output, Cint, ()) == 1   # if we're precompiling the package
    @info "precompiling common combinations of indexes, distances, and databases"
    let
        # Note: something happens that the warming stage is not removed
        # =
        function run_functions(E, queries)
            I, D = searchbatch(E, queries, 3)
            @assert size(I) == (3, length(queries))
            I, D = allknn(E, 3)
            @assert size(I) == (3, length(queries))
            p1, p2, d = closestpair(E)
            @assert p1 != p2
        end

        # running common combinations for precompilation
        for X in [rand(Float32, 2, 16), rand(Float64, 2, 16)] # 32 to force calling triggers / callbacks
            for c in eachcol(X)
                normalize!(c)
            end

            # for dist in [L2Distance(), SqL2Distance(), L1Distance(), CosineDistance(), NormalizedCosineDistance(), AngleDistance(), NormalizedAngleDistance()]
            for dist in [L2Distance(), SqL2Distance(), CosineDistance(), NormalizedCosineDistance()]
                #for db in [MatrixDatabase(X), VectorDatabase(X)]
                for db in [MatrixDatabase(X)]
                    #for db in [db_, rand(db_, 15)]
                        E = ExhaustiveSearch(; db, dist)
                        run_functions(E, db)
                        G = SearchGraph(; db, dist, verbose=false)
                        index!(G)
                        run_functions(G, db)
                        optimize!(G, ParetoRecall())
                        optimize!(G, MinRecall(0.8))
                        optimize!(G, ParetoRadius())
                        try
                            # static databases will throw an error
                            push!(G, db[1])
                            append!(G, db)
                        finally
                            continue
                        end
                    #end
                end
            end
        end
        =#
        #=
        # Skip precompilation of the following combinations since they are not so used but increase significantly the compilation times
        for X in [
                rand(Int64(1):Int64(6), 4, 32), rand(Int32(1):Int32(6), 4, 32), rand(Int16(1):Int16(6), 4, 32), rand(Int8(1):Int8(6), 4, 32),
                rand(UInt64(1):UInt64(6), 4, 32), rand(UInt32(1):UInt32(6), 4, 32), rand(UInt16(1):UInt16(6), 4, 32), rand(UInt8(1):UInt8(6), 4, 32)
            ] # 32 to force calling triggers / callbacks

            for c in eachcol(X)
                sort!(c)
            end

            for dist in [StringHammingDistance(), LevenshteinDistance(), LcsDistance(), JaccardDistance(), DiceDistance(), CosineDistanceSet()]
                for db_ in [MatrixDatabase(X), VectorDatabase(X)]
                    for db in [db_, rand(db_, 30)]
                        E = ExhaustiveSearch(; db, dist)
                        run_functions(E, db)
                        G = SearchGraph(; db, dist, verbose=false)
                        index!(G)
                        run_functions(G, db)
                        optimize!(G, ParetoRecall())
                        optimize!(G, MinRecall(0.8))
                        optimize!(G, ParetoRadius())
                        try
                            # static databases will throw an error
                            push!(G, db[1])
                            append!(G, db)
                        finally
                            continue
                        end
                    end
                end
            end
        end
        = #
    end
end

=#

end  # end SimilaritySearch module
