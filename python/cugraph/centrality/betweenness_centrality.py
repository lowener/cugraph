# Copyright (c) 2019-2020, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import random
import numpy as np
from cugraph.centrality import betweenness_centrality_wrapper
from cugraph.centrality import edge_betweenness_centrality_wrapper


# NOTE: result_type=float could ne an intuitive way to indicate the result type
def betweenness_centrality(G, k=None, normalized=True,
                           weight=None, endpoints=False, implementation=None,
                           seed=None, result_dtype=np.float64):
    """
    Compute the betweenness centrality for all nodes of the graph G from a
    sample of 'k' sources.
    CuGraph does not currently support the 'endpoints' and 'weight' parameters
    as seen in the corresponding networkX call.

    Parameters
    ----------
    G : cuGraph.Graph
        cuGraph graph descriptor with connectivity information. The graph can
        be either directed (DiGraph) or undirected (Graph).
        Weights in the graph are ignored, the current implementation uses
        BFS traversals. Use weight parameter if weights need to be considered
        (currently not supported)

    k : int or list or None, optional, default=None
        If k is not None, use k node samples to estimate betweenness.  Higher
        values give better approximation
        If k is a list, use the content of the list for estimation: the list
        should contain vertices identifiers.
        Vertices obtained through sampling or defined as a list will be used as
        sources for traversals inside the algorithm.

    normalized : bool, optional
        Default is True.
        If true, the betweenness values are normalized by
        2 / ((n - 1) * (n - 2)) for Graphs (undirected), and
        1 / ((n - 1) * (n - 2)) for DiGraphs (directed graphs)
        where n is the number of nodes in G.
        Normalization will ensure that the values in [0, 1],
        this normalization scales fo the highest possible value where one
        node is crossed by every single shortest path.

    weight : cudf.DataFrame, optional, default=None
        Specifies the weights to be used for each edge.
        Should contain a mapping between
        edges and weights.
        (Not Supported)

    endpoints : bool, optional, default=False
        If true, include the endpoints in the shortest path counts.
        (Not Supported)

    implementation : string, optional, default=None
        if implementation is None or "default", uses native cugraph,
        if "gunrock" uses gunrock based bc.
        The default version supports normalized, k and seed options.
        "gunrock" might be faster when considering all the sources, but
        only return float results and consider all the vertices as sources.

    seed : optional
        if k is specified and k is an integer, use seed to initialize the
        random number generator.
        Using None as seed relies on random.seed() behavior: using current
        system time
        If k is either None or list: seed parameter is ignored

    result_dtype : np.float32 or np.float64, optional, default=np.float64
        Indicate the data type of the betweenness centrality scores
        Using double automatically switch implementation to "default"

    Returns
    -------
    df : cudf.DataFrame
        GPU data frame containing two cudf.Series of size V: the vertex
        identifiers and the corresponding betweenness centrality values.
        Please note that the resulting the 'vertex' column might not be
        in ascending order.

        df['vertex'] : cudf.Series
            Contains the vertex identifiers
        df['betweenness_centrality'] : cudf.Series
            Contains the betweenness centrality of vertices

    Examples
    --------
    >>> M = cudf.read_csv('datasets/karate.csv', delimiter=' ',
    >>>                   dtype=['int32', 'int32', 'float32'], header=None)
    >>> G = cugraph.Graph()
    >>> G.from_cudf_edgelist(M, source='0', destination='1')
    >>> bc = cugraph.betweenness_centrality(G)
    """
    # vertices is intended to be a cuDF series that contains a sampling of
    # k vertices out of the graph.
    #
    # NOTE: cuDF doesn't currently support sampling, but there is a python
    # workaround.
    implementation = _initialize_and_verify_implementation(implementation, k)

    vertices, k = _initialize_vertices(G, k, seed)

    if endpoints is True:
        raise NotImplementedError("endpoints accumulation for betweenness "
                                  "centrality not currently supported")

    if weight is not None:
        raise NotImplementedError("weighted implementation of betweenness "
                                  "centrality not currently supported")

    if result_dtype not in [np.float32, np.float64]:
        raise TypeError("result type can only be np.float32 or np.float64")

    df = betweenness_centrality_wrapper.betweenness_centrality(G, normalized,
                                                               endpoints,
                                                               weight,
                                                               k, vertices,
                                                               implementation,
                                                               result_dtype)
    return df


def edge_betweenness_centrality(G, k=None, normalized=True,
                                weight=None, seed=None,
                                result_dtype=np.float64):
    """
    Compute the edge betweenness centrality for all edges of the graph G from a
    sample of 'k' sources.
    CuGraph does not currently support the 'weight' parameter
    as seen in the corresponding networkX call.

    Parameters
    ----------
    G : cuGraph.Graph
        cuGraph graph descriptor with connectivity information. The graph can
        be either directed (DiGraph) or undirected (Graph).
        Weights in the graph are ignored, the current implementation uses
        BFS traversals. Use weight parameter if weights need to be considered
        (currently not supported)

    k : int or list or None, optional, default=None
        If k is not None, use k node samples to estimate betweenness.  Higher
        values give better approximation
        If k is a list, use the content of the list for estimation: the list
        should contain vertices identifiers.
        Vertices obtained through sampling or defined as a list will be used as
        sources for traversals inside the algorithm.

    normalized : bool, optional
        Default is True.
        If true, the betweenness values are normalized by
        2 / ((n - 1) * (n - 2)) for Graphs (undirected), and
        1 / ((n - 1) * (n - 2)) for DiGraphs (directed graphs)
        where n is the number of nodes in G.
        Normalization will ensure that the values in [0, 1],
        this normalization scales fo the highest possible value where one
        node is crossed by every single shortest path.

    weight : cudf.DataFrame, optional, default=None
        Specifies the weights to be used for each edge.
        Should contain a mapping between
        edges and weights.
        (Not Supported)

    seed : optional
        if k is specified and k is an integer, use seed to initialize the
        random number generator.
        Using None as seed relies on random.seed() behavior: using current
        system time
        If k is either None or list: seed parameter is ignored

    result_dtype : np.float32 or np.float64, optional, default=np.float64
        Indicate the data type of the betweenness centrality scores
        Using double automatically switch implementation to "default"

    Returns
    -------
    df : cudf.DataFrame
        GPU data frame containing two cudf.Series of size V: the vertex
        identifiers and the corresponding betweenness centrality values.
        Please note that the resulting the 'vertex' column might not be
        in ascending order.

        df['vertex'] : cudf.Series
            Contains the vertex identifiers
        df['edge_betweenness_centrality'] : cudf.Series
            Contains the betweenness centrality of vertices

    Examples
    --------
    >>> M = cudf.read_csv('datasets/karate.csv', delimiter=' ',
    >>>                   dtype=['int32', 'int32', 'float32'], header=None)
    >>> G = cugraph.Graph()
    >>> G.from_cudf_edgelist(M, source='0', destination='1')
    >>> ebc = cugraph.edge_betweenness_centrality(G)
    """

    vertices, k = _initialize_vertices(G, k, seed)
    if weight is not None:
        raise NotImplementedError("weighted implementation of betweenness "
                                  "centrality not currently supported")
    if result_dtype not in [np.float32, np.float64]:
        raise TypeError("result type can only be np.float32 or np.float64")

    df = edge_betweenness_centrality_wrapper                                  \
        .edge_betweenness_centrality(G, normalized, weight, k, vertices,
                                     result_dtype)
    return df


# =============================================================================
# Internal functions
# =============================================================================
# Parameter: 'implementation'
# -----------------------------------------------------------------------------
#
# Some features are not implemented in gunrock implementation, failing fast,
# but passing parameters through
#

def _initialize_and_verify_implementation(implementation, k):
    if implementation is None:
        implementation = "default"

    if implementation not in ["default", "gunrock"]:
        raise ValueError("Only two implementations are supported: 'default' "
                         "and 'gunrock'")
    if implementation == "gunrock" and k is not None:
        raise ValueError("sampling feature of betweenness "
                         "centrality not currently supported "
                         "with gunrock implementation, "
                         "please use None or 'default'")
    return implementation


# Parameter: 'k' and 'seed'
# -----------------------------------------------------------------------------
# In order to compare with pre-set sources,
# k can either be a list or an integer or None
#  int: Generate an random sample with k elements
# list: k become the length of the list and vertices become the content
# None: All the vertices are considered
def _initialize_vertices(G, k, seed):
    vertices = None
    if k is not None:
        if isinstance(k, int):
            vertices = _initialize_vertices_from_indices_sampling(G, k, seed)
        elif isinstance(k, list):
            vertices, k = _initialize_vertices_from_identifiers_list(G, k)
    return vertices, k


# NOTE: We do not renumber in case k is an int, the sampling is
#       not operating on the valid vertices identifiers but their
#       indices:
# Example:
# - vertex '2' is missing
# - vertices '0' '1' '3' '4' exist
# - There is a vertex at index 2 (there is not guarantee that it is
#   vertice '3' )
def _initialize_vertices_from_indices_sampling(G, k, seed):
    random.seed(seed)
    vertices = random.sample(range(G.number_of_vertices()), k)
    return vertices


def _initialize_vertices_from_identifiers_list(G, identifiers):
    # FIXME: There might be a cleaner way to obtain the inverse mapping
    vertices = identifiers
    if G.renumbered:
        vertices = [G.edgelist.renumber_map[G.edgelist.renumber_map ==
                                            vert].index[0] for vert in
                    vertices]
    k = len(vertices)
    return vertices, k
