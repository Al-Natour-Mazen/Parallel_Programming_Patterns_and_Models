#include <iostream>
#include <exo2/student.h>
#include <OPP_cuda.cuh>

namespace 
{
  struct foncteur {
    __device__
        unsigned operator()(const float& v) const {
      return 256 * v;
    }
  };
}

void StudentWorkImpl::run_Histogram(
	OPP::CUDA::DeviceBuffer<float>& dev_value,
	OPP::CUDA::DeviceBuffer<unsigned>& dev_histogram,
	const unsigned width,
	const unsigned height
) {
	// TODO: build histogram
  OPP::CUDA::computeHistogram<float, unsigned, foncteur>(dev_value, dev_histogram, foncteur());
  cudaDeviceSynchronize();
}
