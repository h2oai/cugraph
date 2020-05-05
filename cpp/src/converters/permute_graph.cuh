/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
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
#include <rmm_utils.h>
#include <graph.hpp>
#include "converters/COOtoCSR.cuh"
#include "utilities/graph_utils.cuh"

namespace cugraph {
namespace detail {

template <typename IdxT>
struct permutation_functor {
  IdxT const *permutation;
  permutation_functor(IdxT const *p) : permutation(p) {}
  __host__ __device__ IdxT operator()(IdxT in) const { return permutation[in]; }
};

/**
 * This function takes a graph and a permutation vector and permutes the
 * graph according to the permutation vector. So each vertex id i becomes
 * vertex id permutation[i] in the permuted graph.
 * @param graph The graph to permute.
 * @param permutation The permutation vector to use, must be a valid permutation
 * i.e. contains all values 0-n exactly once.
 * @return The permuted graph.
 */
template <typename vertex_t, typename edge_t, typename weight_t>
void permute_graph(experimental::GraphCSR<vertex_t, edge_t, weight_t> const &graph,
                   vertex_t const *permutation,
                   experimental::GraphCSR<vertex_t, edge_t, weight_t> &result)
{
  //  Create a COO out of the CSR
  rmm::device_vector<vertex_t> src_vertices_v(graph.number_of_edges);
  rmm::device_vector<vertex_t> dst_vertices_v(graph.number_of_edges);

  vertex_t *d_src = src_vertices_v.data().get();
  vertex_t *d_dst = dst_vertices_v.data().get();

  graph.get_source_indices(d_src);

  thrust::copy(rmm::exec_policy(nullptr)->on(nullptr),
               graph.indices,
               graph.indices + graph.number_of_edges,
               d_dst);

  // Permute the src_indices
  permutation_functor<vertex_t> pf(permutation);
  thrust::transform(
    rmm::exec_policy(nullptr)->on(nullptr), d_src, d_src + graph.number_of_edges, d_src, pf);

  // Permute the destination indices
  thrust::transform(
    rmm::exec_policy(nullptr)->on(nullptr), d_dst, d_dst + graph.number_of_edges, d_dst, pf);

  if (graph.edge_data == nullptr) {
    // Call COO2CSR to get the new adjacency
    CSR_Result<vertex_t> new_csr;
    ConvertCOOtoCSR(d_src, d_dst, (int64_t)graph.number_of_edges, new_csr);

    // Construct the result graph
    result.offsets   = new_csr.rowOffsets;
    result.indices   = new_csr.colIndices;
    result.edge_data = nullptr;
  } else {
    // Call COO2CSR to get the new adjacency
    CSR_Result_Weighted<vertex_t, weight_t> new_csr;
    ConvertCOOtoCSR_weighted(
      d_src, d_dst, graph.edge_data, (int64_t)graph.number_of_edges, new_csr);

    // Construct the result graph
    result.offsets   = new_csr.rowOffsets;
    result.indices   = new_csr.colIndices;
    result.edge_data = new_csr.edgeWeights;
  }

  result.number_of_vertices = graph.number_of_vertices;
  result.number_of_edges    = graph.number_of_edges;
}

}  // namespace detail
}  // namespace cugraph
