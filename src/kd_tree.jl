# A KDNode stores the information needed in each non leaf node
# to make the needed distance computations
immutable KDNode{T}
    lo::T           # The low boundary for the hyper rect in this dimension
    hi::T           # The high boundary for the hyper rect in this dimension
    split_val::T    # The value the hyper rectangle was split at
    split_dim::Int  # The dimension the hyper rectangle was split at
end

immutable KDTree{T <: AbstractFloat, M <: MinkowskiMetric} <: NNTree{T, M}
    data::Matrix{T} # dim x n_p array with floats
    hyper_rec::HyperRectangle{T}
    indices::Vector{Int}
    metric::M
    nodes::Vector{KDNode{T}}
    tree_data::TreeData
    reordered::Bool
end

"""
    KDTree(data [, metric = Euclidean(), leafsize = 10]) -> kdtree

Creates a `KDTree` from the data using the given `metric` and `leafsize`.
The `metric` must be a `MinkowskiMetric`.
"""
function KDTree{T <: AbstractFloat, M <: MinkowskiMetric}(data::Matrix{T},
                                                          metric::M = Euclidean();
                                                          leafsize::Int = 10,
                                                          reorder::Bool = true)

    tree_data = TreeData(data, leafsize)
    n_d = size(data, 1)
    n_p = size(data, 2)

    indices = collect(1:n_p)
    nodes = Array(KDNode{T}, tree_data.n_internal_nodes)

    if reorder
       indices_reordered = Vector{Int}(n_p)
       data_reordered = Matrix{T}(n_d, n_p)
     else
       # Dummy variables
       indices_reordered = Vector{Int}(0)
       data_reordered = Matrix{T}(0, 0)
     end

    # Create first bounding hyper rectangle that bounds all the input points
    hyper_rec = compute_bbox(data)

    # Call the recursive KDTree builder
    build_KDTree(1, data, data_reordered, hyper_rec, nodes, indices, indices_reordered,
                 1, size(data,2), tree_data, reorder)
    if reorder
        data = data_reordered
        indices = indices_reordered
    end

    KDTree{T, M}(data, hyper_rec, indices, metric, nodes, tree_data, reorder)
end

function build_KDTree{T <: AbstractFloat}(index::Int,
                                          data::Matrix{T},
                                          data_reordered::Matrix{T},
                                          hyper_rec::HyperRectangle{T},
                                          nodes::Vector{KDNode{T}},
                                          indices::Vector{Int},
                                          indices_reordered::Vector{Int},
                                          low::Int,
                                          high::Int,
                                          tree_data::TreeData,
                                          reorder::Bool)
    n_p = high - low + 1 # Points left
    if n_p <= tree_data.leafsize
        if reorder
            reorder_data!(data_reordered, data, index, indices, indices_reordered, tree_data)
        end
        return
    end

    mid_idx = find_split(low, tree_data.leafsize, n_p)

    split_dim = 1
    max_spread = zero(T)
    # Find dimension and and spread where the spread is maximal
    for d in 1:size(data, 1)
        spread = hyper_rec.maxes[d] - hyper_rec.mins[d]
        if spread > max_spread
            max_spread = spread
            split_dim = d
        end
    end

    select_spec!(indices, mid_idx, low, high, data, split_dim)

    split_val = data[split_dim, indices[mid_idx]]

    lo = hyper_rec.mins[split_dim]
    hi = hyper_rec.maxes[split_dim]

    nodes[index] = KDNode{T}(lo, hi, split_val, split_dim)

    # Call the left sub tree with an updated hyper rectangle
    hyper_rec.maxes[split_dim] = split_val
    build_KDTree(getleft(index), data, data_reordered, hyper_rec, nodes,
                  indices, indices_reordered, low, mid_idx - 1 , tree_data, reorder)
    hyper_rec.maxes[split_dim] = hi # Restore the hyper rectangle

    # Call the right sub tree with an updated hyper rectangle
    hyper_rec.mins[split_dim] = split_val
    build_KDTree(getright(index), data, data_reordered, hyper_rec, nodes,
                  indices, indices_reordered, mid_idx, high, tree_data, reorder)
    # Restore the hyper rectangle
    hyper_rec.mins[split_dim] = lo
end


function _knn{T}(tree::KDTree{T},
                point::AbstractVector{T},
                k::Int)
    best_idxs = [-1 for _ in 1:k]
    best_dists = [typemax(T) for _ in 1:k]
    init_min = get_min_distance(tree.hyper_rec, point)
    knn_kernel!(tree, 1, point, best_idxs, best_dists, init_min)
    @simd for i in eachindex(best_dists)
        @inbounds best_dists[i] = eval_end(tree.metric, best_dists[i])
    end
    return best_idxs, best_dists
end

function knn_kernel!{T}(tree::KDTree{T},
                        index::Int,
                        point::Vector{T},
                        best_idxs ::Vector{Int},
                        best_dists::Vector{T},
                        min_dist::T)
    @NODE 1
    # At a leaf node. Go through all points in node and add those in range
    if isleaf(tree.tree_data.n_internal_nodes, index)
        add_points_knn!(best_dists, best_idxs, tree, index, point, false)
        return
    end

    node = tree.nodes[index]
    p_dim = point[node.split_dim]
    split_val = node.split_val
    lo = node.lo
    hi = node.hi
    split_diff = p_dim - split_val
    M = tree.metric
    # Point is to the right of the split value
    if split_diff > 0
        close = getright(index)
        far = getleft(index)
        ddiff = max(zero(T), p_dim - hi)
    else
        close = getleft(index)
        far = getright(index)
        ddiff = max(zero(T), lo - p_dim)
    end
    # Always call closer sub tree
    knn_kernel!(tree, close, point, best_idxs, best_dists, min_dist)


    split_diff_pow = eval_pow(M, split_diff)
    ddiff_pow = eval_pow(M, ddiff)
    diff_tot = eval_diff(M, split_diff_pow, ddiff_pow)
    new_min = eval_reduce(M, min_dist, diff_tot)
    if new_min < best_dists[1]
        knn_kernel!(tree, far, point, best_idxs, best_dists, new_min)
    end
    return
end

function _inrange{T}(tree::KDTree{T},
                     point::AbstractVector{T},
                     radius::Number)
    idx_in_ball = Int[]
    init_min = get_min_distance(tree.hyper_rec, point)
    inrange_kernel!(tree, 1, point, eval_op(tree.metric, radius, zero(T)), idx_in_ball,
                   init_min)
    return idx_in_ball
end

# Explicitly check the distance between leaf node and point while traversing
function inrange_kernel!{T}(tree::KDTree{T},
                            index::Int,
                            point::Vector{T},
                            r::Number,
                            idx_in_ball::Vector{Int},
                            min_dist::T)
    @NODE 1
    # Point is outside hyper rectangle, skip the whole sub tree
    if min_dist > r
        return
    end

    # At a leaf node. Go through all points in node and add those in range
    if isleaf(tree.tree_data.n_internal_nodes, index)
        add_points_inrange!(idx_in_ball, tree, index, point, r, false)
        return
    end

    node = tree.nodes[index]
    split_val = node.split_val
    lo = node.lo
    hi = node.hi
    p_dim = point[node.split_dim]
    split_diff = p_dim - split_val
    M = tree.metric

    if split_diff > 0 # Point is to the right of the split value
        close = getright(index)
        far = getleft(index)
        ddiff = max(zero(T), p_dim - hi)
    else # Point is to the left of the split value
        close = getleft(index)
        far = getright(index)
        ddiff = max(zero(T), lo - p_dim)
    end
    # Call closer sub tree
    inrange_kernel!(tree, close, point, r, idx_in_ball, min_dist)

    # TODO: We could potentially also keep track of the max distance
    # between the point and the hyper rectangle and add the whole sub tree
    # in case of the max distance being <= r similarly to the BallTree inrange method.
    # It would be interesting to benchmark this on some different data sets.

    # Call further sub tree with the new min distance
    split_diff_pow = eval_pow(M, split_diff)
    ddiff_pow = eval_pow(M, ddiff)
    diff_tot = eval_diff(M, split_diff_pow, ddiff_pow)
    new_min = eval_reduce(M, min_dist, diff_tot)
    inrange_kernel!(tree, far, point, r, idx_in_ball, new_min)
end
