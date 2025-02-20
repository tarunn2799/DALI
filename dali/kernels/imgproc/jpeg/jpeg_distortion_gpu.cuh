// Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef DALI_KERNELS_IMGPROC_JPEG_JPEG_ARTIFACTS_GPU_H_
#define DALI_KERNELS_IMGPROC_JPEG_JPEG_ARTIFACTS_GPU_H_

#include <cuda_runtime_api.h>
#include "dali/kernels/common/block_setup.h"
#include "dali/kernels/imgproc/surface.h"
#include "dali/kernels/imgproc/sampler.h"
#include "dali/kernels/imgproc/jpeg/dct_8x8_gpu.cuh"
#include "dali/core/geom/vec.h"
#include "dali/core/geom/mat.h"
#include "dali/core/geom/box.h"
#include "dali/core/util.h"

namespace dali {
namespace kernels {

float GetQualityFactorScale(int quality) {
  quality = clamp<int>(quality, 1, 99);
  float q_scale = 1.0f;
  if (quality < 50) {
    q_scale = 50.0f / quality;
  } else {
    q_scale = 2.0f - (2 * quality / 100.0f);
  }
  return q_scale;
}

// Quantization table coefficients that are suggested in the Annex K of the JPEG standard.

mat<8, 8, uint8_t> GetLumaQuantizationTable(int quality) {
  mat<8, 8, uint8_t> table = {{
    {16, 11, 10, 16, 24, 40, 51, 61},
    {12, 12, 14, 19, 26, 58, 60, 55},
    {14, 13, 16, 24, 40, 57, 69, 56},
    {14, 17, 22, 29, 51, 87, 80, 62},
    {18, 22, 37, 56, 68, 109, 103, 77},
    {24, 35, 55, 64, 81, 104, 113, 92},
    {49, 64, 78, 87, 103, 121, 120, 101},
    {72, 92, 95, 98, 112, 100, 103, 99}
  }};
  auto scale = GetQualityFactorScale(quality);
  for (int i = 0; i < 8; i++) {
    for (int j = 0; j < 8; j++) {
      table(i, j) = ConvertSat<uint8_t>(scale * table(i, j));
    }
  }
  return table;
}

mat<8, 8, uint8_t> GetChromaQuantizationTable(int quality) {
  mat<8, 8, uint8_t> table = {{
    {17, 18, 24, 47, 99, 99, 99, 99},
    {18, 21, 26, 66, 99, 99, 99, 99},
    {24, 26, 56, 99, 99, 99, 99, 99},
    {47, 66, 99, 99, 99, 99, 99, 99},
    {99, 99, 99, 99, 99, 99, 99, 99},
    {99, 99, 99, 99, 99, 99, 99, 99},
    {99, 99, 99, 99, 99, 99, 99, 99},
    {99, 99, 99, 99, 99, 99, 99, 99}
  }};
  auto scale = GetQualityFactorScale(quality);
  for (int i = 0; i < 8; i++) {
    for (int j = 0; j < 8; j++) {
      table(i, j) = ConvertSat<uint8_t>(scale * table(i, j));
    }
  }
  return table;
}

struct SampleDesc {
  const uint8_t *in;  // rgb
  uint8_t *out;  // rgb
  ivec<2> size;
  i64vec<2> strides;
  mat<8, 8, uint8_t> luma_Q_table = GetLumaQuantizationTable(95);
  mat<8, 8, uint8_t> chroma_Q_table = GetChromaQuantizationTable(95);
};

template <typename T>
__inline__ __device__ T rgb_to_y(vec<3, T> rgb) {
  return ConvertSat<T>(0.299f * rgb.x + 0.587f * rgb.y + 0.114f * rgb.z);
}

template <typename T>
__inline__ __device__ T rgb_to_cb(vec<3, T> rgb) {
  return ConvertSat<T>(-0.16873589f * rgb.x - 0.33126411f * rgb.y + 0.50000000f * rgb.z + 128.0f);
}

template <typename T>
__inline__ __device__ T rgb_to_cr(vec<3, T> rgb) {
  return ConvertSat<T>(0.50000000f * rgb.x - 0.41868759f * rgb.y - 0.08131241f * rgb.z + 128.0f);
}

template <typename T>
__inline__ __device__ vec<2, T> rgb_to_cb_cr(vec<3, T> rgb) {
  return {rgb_to_cb<T>(rgb), rgb_to_cr<T>(rgb)};
}

template <int N, typename T>
__inline__ __device__ vec<N, T> avg4(vec<N, T> a, vec<N, T> b, vec<N, T> c, vec<N, T> d) {
  IMPL_VEC_ELEMENTWISE(ConvertSat<T>((a[i] + b[i] + c[i] + d[i]) * 0.25f));
}

template <int N, typename T>
__inline__ __device__ vec<N, T> avg2(vec<N, T> a, vec<N, T> b) {
  IMPL_VEC_ELEMENTWISE(ConvertSat<T>((a[i] + b[i]) * 0.5f));
}

template <typename T>
__inline__ __device__ vec<3, T> ycbcr_to_rgb(const vec<3, T> ycbcr) {
    float y  = static_cast<float>(ycbcr.x);
    float cb = static_cast<float>(ycbcr.y) - 128.0f;
    float cr = static_cast<float>(ycbcr.z) - 128.0f;
    vec<3, T> rgb;
    rgb.x = ConvertSat<T>(y + 1.402f * cr);
    rgb.y = ConvertSat<T>(y - 0.34413629f * cb - 0.71413629f * cr);
    rgb.z = ConvertSat<T>(y + 1.772f * cb);
    return rgb;
}


template <typename T, bool horz_subsample, bool vert_subsample>
struct YCbCrSubsampled {
  static constexpr int kLumaLen = (1+horz_subsample)*(1+vert_subsample);
  T luma[kLumaLen];
  T cb, cr;
};

template <bool horz_subsample, bool vert_subsample, typename T>
__inline__ __device__
YCbCrSubsampled<T, horz_subsample, vert_subsample>
rgb_to_ycbcr_subsampled(ivec2 offset, const Surface2D<const uint8_t>& in) {
  const auto sampler = make_sampler<DALI_INTERP_NN>(in);
  YCbCrSubsampled<T, horz_subsample, vert_subsample> out;
  int y = offset.y;
  int x = offset.x;
  vec<3, T> rgb[4];
  sampler(rgb[0].v, ivec2(x, y), BorderClamp());
  out.luma[0] = rgb_to_y<T>(rgb[0]);
  vec<3, T> avg_rgb(rgb[0]);
  if (horz_subsample && vert_subsample) {
    sampler(rgb[1].v, ivec2(x + 1, y), BorderClamp());
    sampler(rgb[2].v, ivec2(x, y + 1), BorderClamp());
    sampler(rgb[3].v, ivec2(x + 1, y + 1), BorderClamp());
    out.luma[1] = rgb_to_y<T>(rgb[1]);
    out.luma[2] = rgb_to_y<T>(rgb[2]);
    out.luma[3] = rgb_to_y<T>(rgb[3]);
    avg_rgb = avg4(rgb[0], rgb[1], rgb[2], rgb[3]);
  } else if (horz_subsample) {
    sampler(rgb[1].v, ivec2(x + 1, y), BorderClamp());
    out.luma[1] = rgb_to_y<T>(rgb[1]);
    avg_rgb = avg2(rgb[0], rgb[1]);
  } else if (vert_subsample) {
    sampler(rgb[1].v, ivec2(x, y + 1), BorderClamp());
    out.luma[1] = rgb_to_y<T>(rgb[1]);
    avg_rgb = avg2(rgb[0], rgb[1]);
  }

  vec<2, T> cbcr = rgb_to_cb_cr<T>(avg_rgb);
  out.cb = cbcr.x;
  out.cr = cbcr.y;
  return out;
}

template <int N, typename T, int ndim>
__inline__ __device__
void write_vec(const Surface<ndim, T> &surf, ivec<ndim> pos, vec<N, T> v) {
  if (all_coords(pos >= 0) && all_coords(pos < surf.size)) {
    T *pixel = &surf(pos);
    #pragma unroll
    for (int i = 0; i < N; i++)
      pixel[i] = v[i];
  }
}

template <bool horz_subsample, bool vert_subsample, typename T>
__inline__ __device__
void ycbcr_to_rgb_subsampled(ivec2 offset, const Surface2D<uint8_t>& out,
                             YCbCrSubsampled<T, horz_subsample, vert_subsample> ycbcr) {
  int y = offset.y;
  int x = offset.x;
  write_vec(out, {x, y}, ycbcr_to_rgb(vec<3, T>(ycbcr.luma[0], ycbcr.cb, ycbcr.cr)));
  if (horz_subsample && vert_subsample) {
    write_vec(out, {x + 1, y}, ycbcr_to_rgb(vec<3, T>(ycbcr.luma[1], ycbcr.cb, ycbcr.cr)));
    write_vec(out, {x, y + 1}, ycbcr_to_rgb(vec<3, T>(ycbcr.luma[2], ycbcr.cb, ycbcr.cr)));
    write_vec(out, {x + 1, y + 1}, ycbcr_to_rgb(vec<3, T>(ycbcr.luma[3], ycbcr.cb, ycbcr.cr)));
  } else if (horz_subsample) {
    write_vec(out, {x + 1, y}, ycbcr_to_rgb(vec<3, T>(ycbcr.luma[1], ycbcr.cb, ycbcr.cr)));
  } else if (vert_subsample) {
    write_vec(out, {x, y + 1}, ycbcr_to_rgb(vec<3, T>(ycbcr.luma[1], ycbcr.cb, ycbcr.cr)));
  }
}

template <bool horz_subsample, bool vert_subsample>
__global__ void ChromaSubsampleDistortion(const SampleDesc *samples,
                                          const kernels::BlockDesc<2> *blocks) {
  using T = uint8_t;
  const auto &block = blocks[blockIdx.x];
  const auto &sample = samples[block.sample_idx];

  int aligned_end_y = align_up(block.end.y, 1 + vert_subsample);
  int aligned_end_x = align_up(block.end.x, 1 + horz_subsample);

  int y_start = threadIdx.y + block.start.y;
  int x_start = threadIdx.x + block.start.x;
  if (y_start >= block.end.y || x_start >= block.end.x) {
    return;
  }

  const Surface2D<const uint8_t> in = {
    sample.in, sample.size, 3, sample.strides, 1
  };

  const Surface2D<uint8_t> out = {
    sample.out, sample.size, 3, sample.strides, 1
  };

  for (int pos_y = y_start; pos_y < aligned_end_y; pos_y += blockDim.y) {
    for (int pos_x = x_start; pos_x < aligned_end_x; pos_x += blockDim.x) {
      int y = pos_y << vert_subsample;
      int x = pos_x << horz_subsample;
      auto ycbcr = rgb_to_ycbcr_subsampled<horz_subsample, vert_subsample, T>(ivec2{x, y}, in);
      ycbcr_to_rgb_subsampled<horz_subsample, vert_subsample, T>(ivec2{x, y}, out, ycbcr);
    }
  }
}

__device__ __inline__ float quantize(float value, float Q_coeff) {
  if (Q_coeff < 1)
    Q_coeff = 1;
  return Q_coeff * roundf(value * __frcp_rn(Q_coeff));
}

/**
 * @brief Produces JPEG compression artifacts by running the lossy part of
 * JPEG compression and decompression.
 */
template <bool horz_subsample, bool vert_subsample, bool quantization = true>
__global__ void JpegCompressionDistortion(const SampleDesc *samples,
                                          const kernels::BlockDesc<2> *blocks) {
  using T = uint8_t;
  const auto &block = blocks[blockIdx.x];
  const auto &sample = samples[block.sample_idx];

  static constexpr int align_y = 8;
  static constexpr int align_x = 8;
  int aligned_start_x = block.start.x & -align_x;  // align down
  int aligned_start_y = block.start.y & -align_y;
  int aligned_end_y = align_up(block.end.y, align_y);
  int aligned_end_x = align_up(block.end.x, align_x);

  // Assuming CUDA block is 32x16, leading to a 2x4 grid of chroma blocks
  // and up to 4x8 blocks of luma.
  const int vert_chroma_blocks = 2;
  const int num_pages = horz_subsample ? vert_subsample ? 2 : 3 : 4;
  const int vert_luma_blocks = vert_chroma_blocks << vert_subsample;
  const int horz_chroma_blocks = 4;
  const int horz_luma_blocks = horz_chroma_blocks << horz_subsample;
  const int chroma_page = vert_chroma_blocks * horz_chroma_blocks;
  const int chroma_blocks = chroma_page * num_pages;
  const int luma_page = vert_luma_blocks * horz_luma_blocks;
  const int luma_blocks = luma_page * num_pages;
  const int total_blocks = 2 * chroma_blocks + luma_blocks;
  __shared__ float flat_blocks[total_blocks][8][9];

  int chroma_x = threadIdx.x & 7;  // % 8
  int chroma_y = threadIdx.y & 7;  // % 8
  ivec2 chroma_blk_xy{threadIdx.x >> 3, threadIdx.y >> 3};  // / 8

  int luma_x = threadIdx.x << horz_subsample;
  int luma_y = threadIdx.y << vert_subsample;
  ivec2 luma_blk_xy{luma_x >> 3, luma_y >> 3};  // / 8
  luma_x = luma_x & 7;  // % 8
  luma_y = luma_y & 7;  // % 8

  float luma_q[1 + vert_subsample][1 + horz_subsample];
  #pragma unroll
  for (int i = 0; i < 1 + vert_subsample; i++) {
    #pragma unroll
    for (int j = 0; j < 1 + horz_subsample; j++)
      luma_q[i][j] = __ldg(&sample.luma_Q_table(luma_y + i, luma_x + j));
  }

  float chroma_q = __ldg(&sample.chroma_Q_table(chroma_y, chroma_x));


  const Surface2D<const uint8_t> in = {
    sample.in, sample.size, 3, sample.strides, 1
  };

  const Surface2D<uint8_t> out = {
    sample.out, sample.size, 3, sample.strides, 1
  };

  const int tid = threadIdx.x + blockDim.x * threadIdx.y;
  const int block_size = blockDim.x * blockDim.y;

  int chroma_block_idx = chroma_blk_xy.y * horz_chroma_blocks + chroma_blk_xy.x;
  int luma_block_idx = luma_blk_xy.y * horz_luma_blocks + luma_blk_xy.x;
  float (*cb)[8][9]   = &flat_blocks[                    chroma_block_idx];
  float (*cr)[8][9]   = &flat_blocks[chroma_blocks     + chroma_block_idx];
  float (*luma)[8][9] = &flat_blocks[chroma_blocks * 2 + luma_block_idx];


  const int ystep = num_pages * vert_chroma_blocks * 8;
  for (int blk_pos_y = aligned_start_y; blk_pos_y < aligned_end_y; blk_pos_y += ystep) {
    for (int blk_pos_x = aligned_start_x; blk_pos_x < aligned_end_x; blk_pos_x += blockDim.x) {
      for (int page = 0; page < num_pages; page++) {
        int pos_x = blk_pos_x + threadIdx.x;
        int pos_y = blk_pos_y + threadIdx.y + page * vert_chroma_blocks * 8;
        int y = pos_y << vert_subsample;
        int x = pos_x << horz_subsample;
        ivec2 offset{x, y};

        auto ycbcr = rgb_to_ycbcr_subsampled<horz_subsample, vert_subsample, T>(offset, in);
        // Shifting to [-128, 128] before the DCT.
        cb[page * chroma_page][chroma_y][chroma_x] = ycbcr.cb - 128.0f;
        cr[page * chroma_page][chroma_y][chroma_x] = ycbcr.cr - 128.0f;
        for (int i = 0, k = 0; i < vert_subsample+1; i++) {
          for (int j = 0; j < horz_subsample+1; j++, k++) {
            luma[page * luma_page][luma_y + i][luma_x + j] = ycbcr.luma[k] - 128.0f;
          }
        }
      }

      __syncthreads();

      static constexpr int col_stride = 1;
      static constexpr int row_stride = 9;
      const int num_dct_slices = total_blocks * 8;

      for (int slice_id = tid; slice_id < num_dct_slices; slice_id += block_size) {
        dct_fwd_8x8_1d<col_stride>(&flat_blocks[slice_id >> 3][slice_id & 7][0]);
      }
      __syncthreads();

      for (int slice_id = tid; slice_id < num_dct_slices; slice_id += block_size) {
        dct_fwd_8x8_1d<row_stride>(&flat_blocks[slice_id >> 3][0][slice_id & 7]);
      }
      __syncthreads();

      if (quantization) {
        for (int page = 0; page < num_pages; page++) {
          int cofs = chroma_page * page;
          int lofs = luma_page * page;
          cb[cofs][chroma_y][chroma_x] = quantize(cb[cofs][chroma_y][chroma_x], chroma_q);
          cr[cofs][chroma_y][chroma_x] = quantize(cr[cofs][chroma_y][chroma_x], chroma_q);
          #pragma unroll
          for (int i = 0, k = 0; i < vert_subsample+1; i++) {
            #pragma unroll
            for (int j = 0; j < horz_subsample+1; j++, k++) {
              float Y = luma[lofs][luma_y + i][luma_x + j];
              luma[lofs][luma_y + i][luma_x + j] = quantize(Y, luma_q[i][j]);
            }
          }
        }
      }
      __syncthreads();

      for (int slice_id = tid; slice_id < num_dct_slices; slice_id += block_size) {
        dct_inv_8x8_1d<row_stride>(&flat_blocks[slice_id >> 3][0][slice_id & 7]);
      }
      __syncthreads();

      for (int slice_id = tid; slice_id < num_dct_slices; slice_id += block_size) {
        dct_inv_8x8_1d<col_stride>(&flat_blocks[slice_id >> 3][slice_id & 7][0]);
      }
      __syncthreads();

      // If we are in the out-of-bounds region, skip
      for (int page = 0; page < num_pages; page++) {
        int pos_x = blk_pos_x + threadIdx.x;
        int pos_y = blk_pos_y + threadIdx.y + page * vert_chroma_blocks * 8;
        int y = pos_y << vert_subsample;
        int x = pos_x << horz_subsample;
        ivec2 offset{x, y};

        if (any_coord(offset >= sample.size)) {
          continue;
        }

        YCbCrSubsampled<T, horz_subsample, vert_subsample> out_ycbcr;
        // Shifting to [0, 255] after the inverse DCT.
        out_ycbcr.cb = ConvertSat<T>(cb[page * chroma_page][chroma_y][chroma_x] + 128.0f);
        out_ycbcr.cr = ConvertSat<T>(cr[page * chroma_page][chroma_y][chroma_x] + 128.0f);
        for (int i = 0, k = 0; i < vert_subsample+1; i++) {
          for (int j = 0; j < horz_subsample+1; j++, k++) {
            float Y = luma[page * luma_page][luma_y + i][luma_x + j];
            out_ycbcr.luma[k] = ConvertSat<T>(Y + 128.0f);
          }
        }
        ycbcr_to_rgb_subsampled<horz_subsample, vert_subsample, T>(offset, out, out_ycbcr);
      }
    }
  }
}

}  // namespace kernels
}  // namespace dali

#endif  // DALI_KERNELS_IMGPROC_JPEG_JPEG_ARTIFACTS_GPU_H_
