#include <OPP/OPP_cuda_buffer.cuh>
#include <OPP/OPP_cuda_histogram.cuh>
#include <exo6/student.h>

#include <OPP_cuda.cuh>
#include <algorithm>
#include <cuda.h>
#include <iostream>
#include <type_traits>

#include <cuda_runtime.h>
#include <cmath>
#include <OPP/OPP_cuda_buffer.cuh>
#include <OPP/OPP_cuda_histogram.cuh>
#include <exo6/student.h>

#include <OPP_cuda.cuh>
#include <algorithm>
#include <cuda.h>
#include <iostream>
#include <type_traits>

namespace {

  /**
   * @brief print a device buffer on standard output
   *
   * @tparam T Datatype of the data stored into the DeviceDuffer
   * @param msg Message to display first (before the data)
   * @param deviceBuffer Contains the data to display
   */
  template <typename T>
  void print(std::string &msg, OPP::CUDA::DeviceBuffer<T> &deviceBuffer)
  {
    const auto size = deviceBuffer.getNbElements();
    std::vector<T> hostVector(size);
    deviceBuffer.copyToHost(hostVector.data());
    std::cout << "======= " << msg << " of size " << size << " =====\n";
    for (unsigned i{0u}; i < size; ++i) {
      std::cout << hostVector[i] << " ";
      if ((i % 16u) == 15u) {
        std::cout << "\n";
      }
    }
  }

  using uchar = unsigned char;

  // CUDA kernel function to build a histogram of pixel intensities and calculate the sum of variances for an image
  __global__
      void buildHistogramAndVarianceSum_kernel(
          const float* const dev_inputValue, // Pointer to the input image data
          unsigned* const dev_histo, // Pointer to the output histogram data
          float* const dev_weight, // Pointer to the output weight data (used for variance calculation)
          const unsigned size, // The total number of pixels in the image
          const unsigned imageWidth) { // The width of the image in pixels

    // Shared memory variables
    __shared__ float shared_sum; // Sum of pixel intensities
    __shared__ unsigned shared_count; // Count of processed pixels
    __shared__ unsigned shared_histo[256]; // Histogram of pixel intensities
    __shared__ float shared_sum_squared_diff; // Sum of squared differences from the mean

    // Initialize shared memory variables
    shared_sum = 0.0f;
    shared_count = 0;
    shared_sum_squared_diff = 0.0f;
    for (unsigned int & i : shared_histo) {
      i = 0;
    }

    // Calculate thread ID and stride
    const unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned stride = blockDim.x * gridDim.x;

    // Each thread processes multiple pixels
    for (unsigned i = tid; i < size; i += stride) {
      float pixel = dev_inputValue[i];
      shared_sum += pixel;
      shared_count++;

      const unsigned xi = min(static_cast<unsigned>(pixel), 255u);
      atomicAdd(&shared_histo[xi], 1u); // Increment histogram bin

      // Calculate indices of left and right neighbors
      const unsigned row = i / imageWidth;
      const unsigned col = i % imageWidth;
      const unsigned left_idx = row * imageWidth + ((col + imageWidth - 1) % imageWidth);
      const unsigned right_idx = row * imageWidth + ((col + 1 ) % imageWidth);

      // Calculate local variance
      const float left_value = dev_inputValue[left_idx];
      const float right_value = dev_inputValue[right_idx];
      const float local_variance = (left_value - pixel) * (left_value - pixel) +
                                   (right_value - pixel) * (right_value - pixel);
      atomicAdd(&dev_weight[xi], local_variance / static_cast<float>(size));
    }

    __syncthreads(); // Synchronize threads

    // First thread in each block calculates the sum and count
    if (threadIdx.x == 0) {
      dev_weight[256] = shared_sum;
      dev_weight[257] = shared_count;
    }

    __syncthreads(); // Synchronize threads

    // Calculate the mean and variance
    if (dev_weight[257] > 0) {
      float mean = dev_weight[256] / dev_weight[257];

      for (unsigned i = tid; i < size; i += stride) {
        float diff = dev_inputValue[i] - mean;
        shared_sum_squared_diff += diff * diff;
      }

      __syncthreads(); // Synchronize threads

      if (threadIdx.x == 0) {
        dev_weight[258] = shared_sum_squared_diff;
      }
    }

    __syncthreads(); // Synchronize threads

    // Copy the shared histogram to global memory
    for (unsigned i = threadIdx.x; i < 256; i += blockDim.x) {
      dev_histo[i] = shared_histo[i];
    }
  }

  // CUDA kernel function to build a cumulative distribution function (CDF) for pixel intensities
  __global__
      void buildCumulativeDistributionFunction_kernel(
          unsigned* const dev_cdf, // Pointer to the output CDF data
          const float* const dev_weight, // Pointer to the input weight data (used for CDF calculation)
          const float lambda, // Regularization term to prevent division by zero
          const unsigned size) { // The total number of pixels in the image

    // Calculate thread ID
    const unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Each thread processes one intensity value
    if (tid < 256) {
      float sum_weights = 0.0f;
      // Calculate the sum of weights for all intensities up to tid
      for (unsigned i = 0; i <= tid; ++i) {
        sum_weights += dev_weight[i];
      }
      // Normalize the sum of weights and store it in the CDF
      float normalized_weight = (sum_weights + lambda) / (size + 256.0f * lambda);
      dev_cdf[tid] = static_cast<unsigned>(normalized_weight * size);
    }
  }

  // CUDA kernel function to apply a transformation to the pixel intensities based on the CDF
  __global__
      void applyTransformation_kernel(
          const float* const dev_inputValue, // Pointer to the input image data
          const unsigned* const dev_cdf, // Pointer to the input CDF data
          float* const dev_outputValue, // Pointer to the output image data
          const unsigned size) { // The total number of pixels in the image

    // Calculate thread ID
    const unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Each thread processes one pixel
    if (tid < size) {
      // Retrieve the intensity of the pixel and cast it to an unsigned char
      const uchar xi = uchar(dev_inputValue[tid]);
      // Retrieve the CDF value for this intensity
      const float cdf_sum = float(dev_cdf[255]);
      // Apply the transformation and store the result in the output image
      dev_outputValue[tid] = 255.0f * dev_cdf[xi] / cdf_sum;
    }
  }

  void buildHistogramAndVarianceSum(OPP::CUDA::DeviceBuffer<float> &dev_inputValue,
                                    OPP::CUDA::DeviceBuffer<unsigned> &dev_cdf,
                                    OPP::CUDA::DeviceBuffer<float> &dev_weight,
                                    const unsigned imageWidth)
  {
    const unsigned nbThreads = 1024;
    const unsigned size = dev_inputValue.getNbElements();

    const dim3 threads(nbThreads);
    const dim3 blocks((size + nbThreads - 1) / nbThreads);

    buildHistogramAndVarianceSum_kernel<<<blocks, threads>>>(
        dev_inputValue.getDevicePointer(),
        dev_cdf.getDevicePointer(),
        dev_weight.getDevicePointer(),
        size,
        imageWidth);
    cudaDeviceSynchronize();
  }

  void buildCumulativeDistributionFunction(OPP::CUDA::DeviceBuffer<unsigned> &dev_cdf,
                                           OPP::CUDA::DeviceBuffer<float> &dev_weight,
                                           const float lambda,
                                           const unsigned size)
  {
    const unsigned nbThreads = 1024;

    const dim3 threads(nbThreads);
    const dim3 blocks((size + nbThreads - 1) / nbThreads);

    buildCumulativeDistributionFunction_kernel<<<blocks, threads>>>(
        dev_cdf.getDevicePointer(),
        dev_weight.getDevicePointer(),
        lambda,
        size);
    cudaDeviceSynchronize();
  }

  void applyTransformation(OPP::CUDA::DeviceBuffer<float> &dev_inputValue,
                           OPP::CUDA::DeviceBuffer<unsigned> &dev_cdf,
                           OPP::CUDA::DeviceBuffer<float> &dev_outputValue)
  {
    const unsigned nbThreads = 1024;
    const unsigned size = dev_inputValue.getNbElements();

    const dim3 threads(nbThreads);
    const dim3 blocks((size + nbThreads - 1) / nbThreads);

    applyTransformation_kernel<<<blocks, threads>>>(
        dev_inputValue.getDevicePointer(),
        dev_cdf.getDevicePointer(),
        dev_outputValue.getDevicePointer(),
        size);
    cudaDeviceSynchronize();
  }
} // namespace

void StudentWorkImpl::run_WHE([[maybe_unused]] OPP::CUDA::DeviceBuffer<float> &dev_inputValue,
                              [[maybe_unused]] OPP::CUDA::DeviceBuffer<unsigned> &dev_histo,
                              [[maybe_unused]] OPP::CUDA::DeviceBuffer<float> &dev_weight,
                              [[maybe_unused]] OPP::CUDA::DeviceBuffer<float> &dev_outputValue,
                              const unsigned imageWidth,
                              const unsigned imageHeight,
                              const float lambda)
{
  // 1. calcul par valeur dans [0..255/256] de l'histogramme ET de la somme des variances/valeur
  ::buildHistogramAndVarianceSum(dev_inputValue, dev_histo, dev_weight, imageWidth);

  // ::print(std::string("histo"), dev_histo); // for debug, if needed
  // ::print(std::string("weight"), dev_weight); // for debug, if needed

  // 2. calcul de la CDF (dans histo pour économiser de la mémoire)
  ::buildCumulativeDistributionFunction(dev_histo, dev_weight, lambda, imageWidth * imageHeight);

  // 3. application de la transformation...
  ::applyTransformation(dev_inputValue, dev_histo, dev_outputValue);
}
/**********************************/
/*   AL NATOUR MAZEN, M1 Info CL  */
/**********************************/