/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <cugraph/detail/graph_utils.cuh>
#include <cugraph/graph_view.hpp>
#include <cugraph/matrix_partition_device_view.cuh>
#include <cugraph/utilities/collect_comm.cuh>
#include <cugraph/utilities/dataframe_buffer.cuh>
#include <cugraph/utilities/error.hpp>
#include <cugraph/utilities/host_barrier.hpp>
#include <cugraph/utilities/host_scalar_comm.cuh>
#include <cugraph/utilities/shuffle_comm.cuh>
#include <cugraph/vertex_partition_device_view.cuh>

#include <cuco/static_map.cuh>
#include <raft/handle.hpp>
#include <rmm/mr/device/per_device_resource.hpp>
#include <rmm/mr/device/polymorphic_allocator.hpp>

#include <type_traits>

namespace cugraph {

namespace detail {

// FIXME: block size requires tuning
int32_t constexpr copy_v_transform_reduce_key_aggregated_out_nbr_for_all_block_size = 1024;

// a workaround for cudaErrorInvalidDeviceFunction error when device lambda is used
template <typename VertexIterator>
struct minor_to_key_t {
  using vertex_t = typename std::iterator_traits<VertexIterator>::value_type;
  VertexIterator adj_matrix_col_key_first{};
  vertex_t minor_first{};
  __device__ vertex_t operator()(vertex_t minor)
  {
    return *(adj_matrix_col_key_first + (minor - minor_first));
  }
};

template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
__global__ void for_all_major_for_all_nbr_mid_degree(
  matrix_partition_device_view_t<vertex_t, edge_t, weight_t, multi_gpu> matrix_partition,
  vertex_t major_first,
  vertex_t major_last,
  vertex_t* majors)
{
  auto const tid = threadIdx.x + blockIdx.x * blockDim.x;
  static_assert(
    copy_v_transform_reduce_key_aggregated_out_nbr_for_all_block_size % raft::warp_size() == 0);
  auto const lane_id      = tid % raft::warp_size();
  auto major_start_offset = static_cast<size_t>(major_first - matrix_partition.get_major_first());
  size_t idx              = static_cast<size_t>(tid / raft::warp_size());

  while (idx < static_cast<size_t>(major_last - major_first)) {
    auto major_offset = major_start_offset + idx;
    auto major =
      matrix_partition.get_major_from_major_offset_nocheck(static_cast<vertex_t>(major_offset));
    vertex_t const* indices{nullptr};
    thrust::optional<weight_t const*> weights{nullptr};
    edge_t local_degree{};
    thrust::tie(indices, weights, local_degree) = matrix_partition.get_local_edges(major_offset);
    auto local_offset                           = matrix_partition.get_local_offset(major_offset);
    for (edge_t i = lane_id; i < local_degree; i += raft::warp_size()) {
      majors[local_offset + i] = major;
    }
    idx += gridDim.x * (blockDim.x / raft::warp_size());
  }
}

template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
__global__ void for_all_major_for_all_nbr_high_degree(
  matrix_partition_device_view_t<vertex_t, edge_t, weight_t, multi_gpu> matrix_partition,
  vertex_t major_first,
  vertex_t major_last,
  vertex_t* majors)
{
  auto major_start_offset = static_cast<size_t>(major_first - matrix_partition.get_major_first());
  size_t idx              = static_cast<size_t>(blockIdx.x);

  while (idx < static_cast<size_t>(major_last - major_first)) {
    auto major_offset = major_start_offset + idx;
    auto major =
      matrix_partition.get_major_from_major_offset_nocheck(static_cast<vertex_t>(major_offset));
    vertex_t const* indices{nullptr};
    thrust::optional<weight_t const*> weights{nullptr};
    edge_t local_degree{};
    thrust::tie(indices, weights, local_degree) =
      matrix_partition.get_local_edges(static_cast<vertex_t>(major_offset));
    auto local_offset = matrix_partition.get_local_offset(major_offset);
    for (edge_t i = threadIdx.x; i < local_degree; i += blockDim.x) {
      majors[local_offset + i] = major;
    }
    idx += gridDim.x;
  }
}

template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
void decompress_matrix_partition_to_fill_edgelist_majors(
  raft::handle_t const& handle,
  matrix_partition_device_view_t<vertex_t, edge_t, weight_t, multi_gpu> matrix_partition,
  vertex_t* majors,
  std::optional<std::vector<vertex_t>> const& segment_offsets)
{
  if (segment_offsets) {
    // FIXME: we may further improve performance by 1) concurrently running kernels on different
    // segments; 2) individually tuning block sizes for different segments; and 3) adding one more
    // segment for very high degree vertices and running segmented reduction
    static_assert(detail::num_sparse_segments_per_vertex_partition == 3);
    if ((*segment_offsets)[1] > 0) {
      raft::grid_1d_block_t update_grid(
        (*segment_offsets)[1],
        detail::copy_v_transform_reduce_key_aggregated_out_nbr_for_all_block_size,
        handle.get_device_properties().maxGridSize[0]);

      detail::for_all_major_for_all_nbr_high_degree<<<update_grid.num_blocks,
                                                      update_grid.block_size,
                                                      0,
                                                      handle.get_stream()>>>(
        matrix_partition,
        matrix_partition.get_major_first(),
        matrix_partition.get_major_first() + (*segment_offsets)[1],
        majors);
    }
    if ((*segment_offsets)[2] - (*segment_offsets)[1] > 0) {
      raft::grid_1d_warp_t update_grid(
        (*segment_offsets)[2] - (*segment_offsets)[1],
        detail::copy_v_transform_reduce_key_aggregated_out_nbr_for_all_block_size,
        handle.get_device_properties().maxGridSize[0]);

      detail::for_all_major_for_all_nbr_mid_degree<<<update_grid.num_blocks,
                                                     update_grid.block_size,
                                                     0,
                                                     handle.get_stream()>>>(
        matrix_partition,
        matrix_partition.get_major_first() + (*segment_offsets)[1],
        matrix_partition.get_major_first() + (*segment_offsets)[2],
        majors);
    }
    if ((*segment_offsets)[3] - (*segment_offsets)[2] > 0) {
      thrust::for_each(
        rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
        thrust::make_counting_iterator(matrix_partition.get_major_first()) + (*segment_offsets)[2],
        thrust::make_counting_iterator(matrix_partition.get_major_first()) + (*segment_offsets)[3],
        [matrix_partition, majors] __device__(auto major) {
          auto major_offset = matrix_partition.get_major_offset_from_major_nocheck(major);
          auto local_degree = matrix_partition.get_local_degree(major_offset);
          auto local_offset = matrix_partition.get_local_offset(major_offset);
          thrust::fill(
            thrust::seq, majors + local_offset, majors + local_offset + local_degree, major);
        });
    }
    if (matrix_partition.get_dcs_nzd_vertex_count() &&
        (*(matrix_partition.get_dcs_nzd_vertex_count()) > 0)) {
      thrust::for_each(
        rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
        thrust::make_counting_iterator(vertex_t{0}),
        thrust::make_counting_iterator(*(matrix_partition.get_dcs_nzd_vertex_count())),
        [matrix_partition, major_start_offset = (*segment_offsets)[3], majors] __device__(
          auto idx) {
          auto major = *(matrix_partition.get_major_from_major_hypersparse_idx_nocheck(idx));
          auto major_idx =
            major_start_offset + idx;  // major_offset != major_idx in the hypersparse region
          auto local_degree = matrix_partition.get_local_degree(major_idx);
          auto local_offset = matrix_partition.get_local_offset(major_idx);
          thrust::fill(
            thrust::seq, majors + local_offset, majors + local_offset + local_degree, major);
        });
    }
  } else {
    thrust::for_each(
      rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
      thrust::make_counting_iterator(matrix_partition.get_major_first()),
      thrust::make_counting_iterator(matrix_partition.get_major_first()) +
        matrix_partition.get_major_size(),
      [matrix_partition, majors] __device__(auto major) {
        auto major_offset = matrix_partition.get_major_offset_from_major_nocheck(major);
        auto local_degree = matrix_partition.get_local_degree(major_offset);
        auto local_offset = matrix_partition.get_local_offset(major_offset);
        thrust::fill(
          thrust::seq, majors + local_offset, majors + local_offset + local_degree, major);
      });
  }
}

}  // namespace detail

/**
 * @brief Iterate over every vertex's key-aggregated outgoing edges to update vertex properties.
 *
 * This function is inspired by thrust::transfrom_reduce() (iteration over the outgoing edges
 * part) and thrust::copy() (update vertex properties part, take transform_reduce output as copy
 * input).
 * Unlike copy_v_transform_reduce_out_nbr, this function first aggregates outgoing edges by key to
 * support two level reduction for every vertex.
 *
 * @tparam GraphViewType Type of the passed non-owning graph object.
 * @tparam AdjMatrixRowValueInputIterator Type of the iterator for graph adjacency matrix row
 * input properties.
 * @tparam VertexIterator Type of the iterator for graph adjacency matrix column key values for
 * aggregation (key type should coincide with vertex type).
 * @tparam ValueIterator Type of the iterator for values in (key, value) pairs.
 * @tparam KeyAggregatedEdgeOp Type of the quinary key-aggregated edge operator.
 * @tparam ReduceOp Type of the binary reduction operator.
 * @tparam T Type of the initial value for reduction over the key-aggregated outgoing edges.
 * @tparam VertexValueOutputIterator Type of the iterator for vertex output property variables.
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Non-owning graph object.
 * @param adj_matrix_row_value_input_first Iterator pointing to the adjacency matrix row input
 * properties for the first (inclusive) row (assigned to this process in multi-GPU).
 * `adj_matrix_row_value_input_last` (exclusive) is deduced as @p adj_matrix_row_value_input_first
 * + @p graph_view.get_number_of_local_adj_matrix_partition_rows().
 * @param adj_matrix_col_key_first Iterator pointing to the adjacency matrix column key (for
 * aggregation) for the first (inclusive) column (assigned to this process in multi-GPU).
 * `adj_matrix_col_key_last` (exclusive) is deduced as @p adj_matrix_col_key_first + @p
 * graph_view.get_number_of_local_adj_matrix_partition_cols().
 * @param map_key_first Iterator pointing to the first (inclusive) key in (key, value) pairs
 * (assigned to this process in multi-GPU,
 * `cugraph::detail::compute_gpu_id_from_vertex_t` is used to map keys to processes).
 * (Key, value) pairs may be provided by transform_reduce_by_adj_matrix_row_key_e() or
 * transform_reduce_by_adj_matrix_col_key_e().
 * @param map_key_last Iterator pointing to the last (exclusive) key in (key, value) pairs (assigned
 * to this process in multi-GPU).
 * @param map_value_first Iterator pointing to the first (inclusive) value in (key, value) pairs
 * (assigned to this process in multi-GPU). `map_value_last` (exclusive) is deduced as @p
 * map_value_first + thrust::distance(@p map_key_first, @p map_key_last).
 * @param key_aggregated_e_op Quinary operator takes edge source, key, aggregated edge weight, *(@p
 * adj_matrix_row_value_input_first + i), and value for the key stored in the input (key, value)
 * pairs provided by @p map_key_first, @p map_key_last, and @p map_value_first (aggregated over the
 * entire set of processes in multi-GPU).
 * @param reduce_op Binary operator takes two input arguments and reduce the two variables to one.
 * @param init Initial value to be added to the reduced @p reduce_op return values for each vertex.
 * @param vertex_value_output_first Iterator pointing to the vertex property variables for the
 * first (inclusive) vertex (assigned to tihs process in multi-GPU). `vertex_value_output_last`
 * (exclusive) is deduced as @p vertex_value_output_first + @p
 * graph_view.get_number_of_local_vertices().
 */
template <typename GraphViewType,
          typename AdjMatrixRowValueInputIterator,
          typename VertexIterator0,
          typename VertexIterator1,
          typename ValueIterator,
          typename KeyAggregatedEdgeOp,
          typename ReduceOp,
          typename T,
          typename VertexValueOutputIterator>
void copy_v_transform_reduce_key_aggregated_out_nbr(
  raft::handle_t const& handle,
  GraphViewType const& graph_view,
  AdjMatrixRowValueInputIterator adj_matrix_row_value_input_first,
  VertexIterator0 adj_matrix_col_key_first,
  VertexIterator1 map_key_first,
  VertexIterator1 map_key_last,
  ValueIterator map_value_first,
  KeyAggregatedEdgeOp key_aggregated_e_op,
  ReduceOp reduce_op,
  T init,
  VertexValueOutputIterator vertex_value_output_first)
{
  static_assert(!GraphViewType::is_adj_matrix_transposed,
                "GraphViewType should support the push model.");
  static_assert(std::is_same<typename std::iterator_traits<VertexIterator0>::value_type,
                             typename GraphViewType::vertex_type>::value);
  static_assert(std::is_same<typename std::iterator_traits<VertexIterator0>::value_type,
                             typename std::iterator_traits<VertexIterator1>::value_type>::value);
  static_assert(is_arithmetic_or_thrust_tuple_of_arithmetic<T>::value);

  using vertex_t = typename GraphViewType::vertex_type;
  using edge_t   = typename GraphViewType::edge_type;
  using weight_t = typename GraphViewType::weight_type;
  using value_t  = typename std::iterator_traits<ValueIterator>::value_type;

  double constexpr load_factor = 0.7;

  // 1. build a cuco::static_map object for the k, v pairs.

  auto poly_alloc = rmm::mr::polymorphic_allocator<char>(rmm::mr::get_current_device_resource());
  auto stream_adapter = rmm::mr::make_stream_allocator_adaptor(poly_alloc, cudaStream_t{nullptr});
  auto kv_map_ptr     = std::make_unique<
    cuco::static_map<vertex_t, value_t, cuda::thread_scope_device, decltype(stream_adapter)>>(
    size_t{0},
    invalid_vertex_id<vertex_t>::value,
    invalid_vertex_id<vertex_t>::value,
    stream_adapter);
  if (GraphViewType::is_multi_gpu) {
    auto& comm               = handle.get_comms();
    auto& row_comm           = handle.get_subcomm(cugraph::partition_2d::key_naming_t().row_name());
    auto const row_comm_rank = row_comm.get_rank();
    auto const row_comm_size = row_comm.get_size();

    // barrier is necessary here to avoid potential overlap (which can leads to deadlock) between
    // two different communicators (beginning of row_comm)
#if 1
    // FIXME: temporary hack till UCC is integrated into RAFT (so we can use UCC barrier with DASK
    // and MPI barrier with MPI)
    host_barrier(comm, handle.get_stream_view());
#else
    handle.get_stream_view().synchronize();
    comm.barrier();  // currently, this is ncclAllReduce
#endif

    auto map_counts =
      host_scalar_allgather(row_comm,
                            static_cast<size_t>(thrust::distance(map_key_first, map_key_last)),
                            handle.get_stream());
    std::vector<size_t> map_displacements(row_comm_size, size_t{0});
    std::partial_sum(map_counts.begin(), map_counts.end() - 1, map_displacements.begin() + 1);
    rmm::device_uvector<vertex_t> map_keys(map_displacements.back() + map_counts.back(),
                                           handle.get_stream());
    auto map_value_buffer =
      allocate_dataframe_buffer<value_t>(map_keys.size(), handle.get_stream());
    for (int i = 0; i < row_comm_size; ++i) {
      device_bcast(row_comm,
                   map_key_first,
                   map_keys.begin() + map_displacements[i],
                   map_counts[i],
                   i,
                   handle.get_stream());
      device_bcast(row_comm,
                   map_value_first,
                   get_dataframe_buffer_begin<value_t>(map_value_buffer) + map_displacements[i],
                   map_counts[i],
                   i,
                   handle.get_stream());
    }
    // FIXME: these copies are unnecessary, better fix RAFT comm's bcast to take separate input &
    // output pointers
    thrust::copy(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                 map_key_first,
                 map_key_last,
                 map_keys.begin() + map_displacements[row_comm_rank]);
    thrust::copy(
      rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
      map_value_first,
      map_value_first + thrust::distance(map_key_first, map_key_last),
      get_dataframe_buffer_begin<value_t>(map_value_buffer) + map_displacements[row_comm_rank]);

    handle.get_stream_view().synchronize();  // cuco::static_map currently does not take stream

    kv_map_ptr.reset();

    kv_map_ptr = std::make_unique<
      cuco::static_map<vertex_t, value_t, cuda::thread_scope_device, decltype(stream_adapter)>>(
      // cuco::static_map requires at least one empty slot
      std::max(static_cast<size_t>(static_cast<double>(map_keys.size()) / load_factor),
               static_cast<size_t>(thrust::distance(map_key_first, map_key_last)) + 1),
      invalid_vertex_id<vertex_t>::value,
      invalid_vertex_id<vertex_t>::value,
      stream_adapter);

    auto pair_first = thrust::make_zip_iterator(
      thrust::make_tuple(map_keys.begin(), get_dataframe_buffer_begin<value_t>(map_value_buffer)));
    kv_map_ptr->insert(pair_first, pair_first + map_keys.size());
  } else {
    handle.get_stream_view().synchronize();  // cuco::static_map currently does not take stream

    kv_map_ptr.reset();

    kv_map_ptr = std::make_unique<
      cuco::static_map<vertex_t, value_t, cuda::thread_scope_device, decltype(stream_adapter)>>(
      // cuco::static_map requires at least one empty slot
      std::max(static_cast<size_t>(
                 static_cast<double>(thrust::distance(map_key_first, map_key_last)) / load_factor),
               static_cast<size_t>(thrust::distance(map_key_first, map_key_last)) + 1),
      invalid_vertex_id<vertex_t>::value,
      invalid_vertex_id<vertex_t>::value,
      stream_adapter);

    auto pair_first = thrust::make_zip_iterator(thrust::make_tuple(map_key_first, map_value_first));
    kv_map_ptr->insert(pair_first, pair_first + thrust::distance(map_key_first, map_key_last));
  }

  // 2. aggregate each vertex out-going edges based on keys and transform-reduce.

  if (GraphViewType::is_multi_gpu) {
    auto& comm = handle.get_comms();

    // barrier is necessary here to avoid potential overlap (which can leads to deadlock) between
    // two different communicators (beginning of col_comm)
#if 1
    // FIXME: temporary hack till UCC is integrated into RAFT (so we can use UCC barrier with DASK
    // and MPI barrier with MPI)
    host_barrier(comm, handle.get_stream_view());
#else
    handle.get_stream_view().synchronize();
    comm.barrier();  // currently, this is ncclAllReduce
#endif
  }

  rmm::device_uvector<vertex_t> major_vertices(0, handle.get_stream());
  auto e_op_result_buffer = allocate_dataframe_buffer<T>(0, handle.get_stream());
  for (size_t i = 0; i < graph_view.get_number_of_local_adj_matrix_partitions(); ++i) {
    auto matrix_partition =
      matrix_partition_device_view_t<vertex_t, edge_t, weight_t, GraphViewType::is_multi_gpu>(
        graph_view.get_matrix_partition_view(i));

    rmm::device_uvector<vertex_t> tmp_major_vertices(matrix_partition.get_number_of_edges(),
                                                     handle.get_stream());
    rmm::device_uvector<vertex_t> tmp_minor_keys(tmp_major_vertices.size(), handle.get_stream());
    rmm::device_uvector<weight_t> tmp_key_aggregated_edge_weights(
      graph_view.is_weighted() ? tmp_major_vertices.size() : size_t{0}, handle.get_stream());

    if (matrix_partition.get_major_size() > 0) {
      auto minor_key_first = thrust::make_transform_iterator(
        matrix_partition.get_indices(),
        detail::minor_to_key_t<VertexIterator0>{adj_matrix_col_key_first,
                                                matrix_partition.get_minor_first()});
      thrust::copy(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                   minor_key_first,
                   minor_key_first + matrix_partition.get_number_of_edges(),
                   tmp_minor_keys.begin());
      if (graph_view.is_weighted()) {
        thrust::copy(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                     *(matrix_partition.get_weights()),
                     *(matrix_partition.get_weights()) + matrix_partition.get_number_of_edges(),
                     tmp_key_aggregated_edge_weights.begin());
      }
      detail::decompress_matrix_partition_to_fill_edgelist_majors(
        handle,
        matrix_partition,
        tmp_major_vertices.data(),
        graph_view.get_local_adj_matrix_partition_segment_offsets(i));
      rmm::device_uvector<vertex_t> reduced_major_vertices(tmp_major_vertices.size(),
                                                           handle.get_stream());
      rmm::device_uvector<vertex_t> reduced_minor_keys(reduced_major_vertices.size(),
                                                       handle.get_stream());
      rmm::device_uvector<weight_t> reduced_key_aggregated_edge_weights(
        reduced_major_vertices.size(), handle.get_stream());
      size_t reduced_size{};
      // FIXME: cub segmented sort may be more efficient as this is already sorted by major
      auto input_key_first = thrust::make_zip_iterator(
        thrust::make_tuple(tmp_major_vertices.begin(), tmp_minor_keys.begin()));
      auto output_key_first = thrust::make_zip_iterator(
        thrust::make_tuple(reduced_major_vertices.begin(), reduced_minor_keys.begin()));
      if (graph_view.is_weighted()) {
        thrust::sort_by_key(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                            input_key_first,
                            input_key_first + tmp_major_vertices.size(),
                            tmp_key_aggregated_edge_weights.begin());
        reduced_size =
          thrust::distance(output_key_first,
                           thrust::get<0>(thrust::reduce_by_key(
                             rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                             input_key_first,
                             input_key_first + tmp_major_vertices.size(),
                             tmp_key_aggregated_edge_weights.begin(),
                             output_key_first,
                             reduced_key_aggregated_edge_weights.begin())));
      } else {
        thrust::sort(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                     input_key_first,
                     input_key_first + tmp_major_vertices.size());
        reduced_size =
          thrust::distance(output_key_first,
                           thrust::get<0>(thrust::reduce_by_key(
                             rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                             input_key_first,
                             input_key_first + tmp_major_vertices.size(),
                             thrust::make_constant_iterator(weight_t{1.0}),
                             output_key_first,
                             reduced_key_aggregated_edge_weights.begin())));
      }
      tmp_major_vertices              = std::move(reduced_major_vertices);
      tmp_minor_keys                  = std::move(reduced_minor_keys);
      tmp_key_aggregated_edge_weights = std::move(reduced_key_aggregated_edge_weights);
      tmp_major_vertices.resize(reduced_size, handle.get_stream());
      tmp_minor_keys.resize(tmp_major_vertices.size(), handle.get_stream());
      tmp_key_aggregated_edge_weights.resize(tmp_major_vertices.size(), handle.get_stream());
      tmp_major_vertices.shrink_to_fit(handle.get_stream());
      tmp_minor_keys.shrink_to_fit(handle.get_stream());
      tmp_key_aggregated_edge_weights.shrink_to_fit(handle.get_stream());
    }

    if (GraphViewType::is_multi_gpu) {
      auto& comm           = handle.get_comms();
      auto const comm_size = comm.get_size();

      auto& row_comm = handle.get_subcomm(cugraph::partition_2d::key_naming_t().row_name());
      auto const row_comm_size = row_comm.get_size();

      auto& col_comm = handle.get_subcomm(cugraph::partition_2d::key_naming_t().col_name());
      auto const col_comm_size = col_comm.get_size();

      auto triplet_first =
        thrust::make_zip_iterator(thrust::make_tuple(tmp_major_vertices.begin(),
                                                     tmp_minor_keys.begin(),
                                                     tmp_key_aggregated_edge_weights.begin()));
      rmm::device_uvector<vertex_t> rx_major_vertices(0, handle.get_stream());
      rmm::device_uvector<vertex_t> rx_minor_keys(0, handle.get_stream());
      rmm::device_uvector<weight_t> rx_key_aggregated_edge_weights(0, handle.get_stream());
      std::forward_as_tuple(
        std::tie(rx_major_vertices, rx_minor_keys, rx_key_aggregated_edge_weights), std::ignore) =
        groupby_gpuid_and_shuffle_values(
          col_comm,
          triplet_first,
          triplet_first + tmp_major_vertices.size(),
          [key_func = detail::compute_gpu_id_from_vertex_t<vertex_t>{comm_size},
           row_comm_size] __device__(auto val) {
            return key_func(thrust::get<1>(val)) / row_comm_size;
          },
          handle.get_stream());

      auto pair_first = thrust::make_zip_iterator(
        thrust::make_tuple(rx_major_vertices.begin(), rx_minor_keys.begin()));
      thrust::sort_by_key(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                          pair_first,
                          pair_first + rx_major_vertices.size(),
                          rx_key_aggregated_edge_weights.begin());
      tmp_major_vertices.resize(rx_major_vertices.size(), handle.get_stream());
      tmp_minor_keys.resize(tmp_major_vertices.size(), handle.get_stream());
      tmp_key_aggregated_edge_weights.resize(tmp_major_vertices.size(), handle.get_stream());
      auto pair_it =
        thrust::reduce_by_key(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                              pair_first,
                              pair_first + rx_major_vertices.size(),
                              rx_key_aggregated_edge_weights.begin(),
                              thrust::make_zip_iterator(thrust::make_tuple(
                                tmp_major_vertices.begin(), tmp_minor_keys.begin())),
                              tmp_key_aggregated_edge_weights.begin());
      tmp_major_vertices.resize(
        thrust::distance(tmp_key_aggregated_edge_weights.begin(), thrust::get<1>(pair_it)),
        handle.get_stream());
      tmp_minor_keys.resize(tmp_major_vertices.size(), handle.get_stream());
      tmp_key_aggregated_edge_weights.resize(tmp_major_vertices.size(), handle.get_stream());
      tmp_major_vertices.shrink_to_fit(handle.get_stream());
      tmp_minor_keys.shrink_to_fit(handle.get_stream());
      tmp_key_aggregated_edge_weights.shrink_to_fit(handle.get_stream());
    }

    auto tmp_e_op_result_buffer =
      allocate_dataframe_buffer<T>(tmp_major_vertices.size(), handle.get_stream());
    auto tmp_e_op_result_buffer_first = get_dataframe_buffer_begin<T>(tmp_e_op_result_buffer);

    auto triplet_first = thrust::make_zip_iterator(thrust::make_tuple(
      tmp_major_vertices.begin(), tmp_minor_keys.begin(), tmp_key_aggregated_edge_weights.begin()));
    thrust::transform(
      rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
      triplet_first,
      triplet_first + tmp_major_vertices.size(),
      tmp_e_op_result_buffer_first,
      [adj_matrix_row_value_input_first =
         adj_matrix_row_value_input_first + matrix_partition.get_major_value_start_offset(),
       key_aggregated_e_op,
       matrix_partition,
       kv_map = kv_map_ptr->get_device_view()] __device__(auto val) {
        auto major = thrust::get<0>(val);
        auto key   = thrust::get<1>(val);
        auto w     = thrust::get<2>(val);
        return key_aggregated_e_op(major,
                                   key,
                                   w,
                                   *(adj_matrix_row_value_input_first +
                                     matrix_partition.get_major_offset_from_major_nocheck(major)),
                                   kv_map.find(key)->second.load(cuda::std::memory_order_relaxed));
      });
    tmp_minor_keys.resize(0, handle.get_stream());
    tmp_key_aggregated_edge_weights.resize(0, handle.get_stream());
    tmp_minor_keys.shrink_to_fit(handle.get_stream());
    tmp_key_aggregated_edge_weights.shrink_to_fit(handle.get_stream());

    if (GraphViewType::is_multi_gpu) {
      auto& col_comm = handle.get_subcomm(cugraph::partition_2d::key_naming_t().col_name());
      auto const col_comm_rank = col_comm.get_rank();
      auto const col_comm_size = col_comm.get_size();

      // FIXME: additional optimization is possible if reduce_op is a pure function (and reduce_op
      // can be mapped to ncclRedOp_t).

      auto rx_sizes =
        host_scalar_gather(col_comm, tmp_major_vertices.size(), i, handle.get_stream());
      std::vector<size_t> rx_displs{};
      rmm::device_uvector<vertex_t> rx_major_vertices(0, handle.get_stream());
      if (static_cast<size_t>(col_comm_rank) == i) {
        rx_displs.assign(col_comm_size, size_t{0});
        std::partial_sum(rx_sizes.begin(), rx_sizes.end() - 1, rx_displs.begin() + 1);
        rx_major_vertices.resize(rx_displs.back() + rx_sizes.back(), handle.get_stream());
      }
      auto rx_tmp_e_op_result_buffer =
        allocate_dataframe_buffer<T>(rx_major_vertices.size(), handle.get_stream());

      device_gatherv(col_comm,
                     tmp_major_vertices.data(),
                     rx_major_vertices.data(),
                     tmp_major_vertices.size(),
                     rx_sizes,
                     rx_displs,
                     i,
                     handle.get_stream());
      device_gatherv(col_comm,
                     tmp_e_op_result_buffer_first,
                     get_dataframe_buffer_begin<T>(rx_tmp_e_op_result_buffer),
                     tmp_major_vertices.size(),
                     rx_sizes,
                     rx_displs,
                     i,
                     handle.get_stream());

      if (static_cast<size_t>(col_comm_rank) == i) {
        major_vertices     = std::move(rx_major_vertices);
        e_op_result_buffer = std::move(rx_tmp_e_op_result_buffer);
      }
    } else {
      major_vertices     = std::move(tmp_major_vertices);
      e_op_result_buffer = std::move(tmp_e_op_result_buffer);
    }
  }

  if (GraphViewType::is_multi_gpu) {
    auto& comm = handle.get_comms();

    // barrier is necessary here to avoid potential overlap (which can leads to deadlock) between
    // two different communicators (beginning of col_comm)
#if 1
    // FIXME: temporary hack till UCC is integrated into RAFT (so we can use UCC barrier with DASK
    // and MPI barrier with MPI)
    host_barrier(comm, handle.get_stream_view());
#else
    handle.get_stream_view().synchronize();
    comm.barrier();  // currently, this is ncclAllReduce
#endif
  }

  thrust::fill(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
               vertex_value_output_first,
               vertex_value_output_first + graph_view.get_number_of_local_vertices(),
               T{});
  thrust::sort_by_key(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                      major_vertices.begin(),
                      major_vertices.end(),
                      get_dataframe_buffer_begin<T>(e_op_result_buffer));

  auto num_uniques = thrust::count_if(
    rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
    thrust::make_counting_iterator(size_t{0}),
    thrust::make_counting_iterator(major_vertices.size()),
    [major_vertices = major_vertices.data()] __device__(auto i) {
      return ((i == 0) || (major_vertices[i] != major_vertices[i - 1])) ? true : false;
    });
  rmm::device_uvector<vertex_t> unique_major_vertices(num_uniques, handle.get_stream());

  auto major_vertex_first = thrust::make_transform_iterator(
    thrust::make_counting_iterator(size_t{0}),
    [major_vertices = major_vertices.data()] __device__(auto i) {
      return ((i == 0) || (major_vertices[i] != major_vertices[i - 1]))
               ? major_vertices[i]
               : invalid_vertex_id<vertex_t>::value;
    });
  thrust::copy_if(
    rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
    major_vertex_first,
    major_vertex_first + major_vertices.size(),
    unique_major_vertices.begin(),
    [] __device__(auto major) { return major != invalid_vertex_id<vertex_t>::value; });
  thrust::reduce_by_key(
    rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
    major_vertices.begin(),
    major_vertices.end(),
    get_dataframe_buffer_begin<T>(e_op_result_buffer),
    thrust::make_discard_iterator(),
    thrust::make_permutation_iterator(
      vertex_value_output_first,
      thrust::make_transform_iterator(
        unique_major_vertices.begin(),
        [vertex_partition = vertex_partition_device_view_t<vertex_t, GraphViewType::is_multi_gpu>(
           graph_view.get_vertex_partition_view())] __device__(auto v) {
          return vertex_partition.get_local_vertex_offset_from_vertex_nocheck(v);
        })),
    thrust::equal_to<vertex_t>{},
    reduce_op);

  thrust::transform(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                    vertex_value_output_first,
                    vertex_value_output_first + graph_view.get_number_of_local_vertices(),
                    vertex_value_output_first,
                    [reduce_op, init] __device__(auto val) { return reduce_op(val, init); });
}

}  // namespace cugraph