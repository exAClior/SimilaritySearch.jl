# This file is a part of SimilaritySearch.jl
# License is Apache 2.0: https://www.apache.org/licenses/LICENSE-2.0.txt

export VorNeighborhood

struct VorNeighborhood <: NeighborhoodAlgorithm
    base::Float64
end

function VorNeighborhood()
    return VorNeighborhood(1.1)
end

function optimize_neighborhood!(algo::VorNeighborhood, index::SearchGraph{T}, dist::Function, perf, recall) where T
end

function neighborhood(algo::VorNeighborhood, index::SearchGraph{T}, dist::Function, item::T, knn, N) where T
    k = max(1, ceil(Int, log(algo.base, n)))
    reset!(knn, k)
    empty!(N)
    n = length(index.db)
    search(index, dist, item, knn)

    @inbounds for p in knn
        pobj = index.db[p.objID]
        covered = false
        for nearID in N
            d = convert(Float32, dist(index.db[nearID], pobj))
            if d <= p.dist
                covered = true
                break
            end
        end

        !covered && push!(N, p.objID)
    end
end
