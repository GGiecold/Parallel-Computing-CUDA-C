/* Illustration of texture memory - another type of cached, read-only memory
   (see also 4.Constant_memory) - amenable to providing higher memory bandwidth
   in certain read-access situations. Namely, those read-access patterns are
   the ones displaying spatial locality (when a thread reads from an address
   spatially adjacent in a grid to the addresses read by neighboring threads).

   The code herewith pertains to one-dimensional texture memory.
   For how to use two-dimensional texture memory, please refer to
     heat_transfer_simulation_with_2D_texture_memory.cu
   in the same directory.

   Compile as follows at the CLI:

     nvcc heat_transfer_simulation_with_texture_memory.cu -o img.o -lGL -lGLU -glut
*/


#include <cuda.h>
#include <stdio.h>
#include "../Common/animate.h"
#include "../Common/errors.h"
#include "../Common/lib.h"  // for the float_to_color kernel


#define DIM 1024
#define MAX_TEMPERATURE 1.0f
#define MIN_TEMPERATURE 0.0001f
#define SPEED 0.2f
#define TIME_STEPS_PER_FRAME 50


struct Data {
  cudaEvent_t start, stop;
  float compute_time;

  AnimateBitmap *bitmap;
  unsigned char *device_bitmap;
  float count_frames;

  float *device_heaters;
  float *device_input;
  float *device_output;
};


void animate_display(Data *, int);
void animate_exit(Data *);
__global__ void maintain_heaters(float *);
__global__ void temperature_update(float *, bool);


// texture references must be declared at file scope
texture<float> texture_heaters;
texture<float> texture_input;
texture<float> texture_output;


int main(void)
{
  Data data;
  
  AnimateBitmap bitmap(DIM, DIM, &data);
  data.bitmap = &bitmap;
  
  data.compute_time = 0.0f;
  data.count_frames = 0;
  
  HANDLE_ERROR(cudaEventCreate(&data.start));
  HANDLE_ERROR(cudaEventCreate(&data.stop));

  HANDLE_ERROR(cudaMalloc((void **) &data.device_bitmap, bitmap.size()));
  HANDLE_ERROR(cudaMalloc((void **) &data.device_heaters, bitmap.size()));
  HANDLE_ERROR(cudaMalloc((void **) &data.device_input, bitmap.size()));
  HANDLE_ERROR(cudaMalloc((void **) &data.device_output, bitmap.size()));

  HANDLE_ERROR(cudaBindTexture(NULL, texture_heaters,
    data.device_heaters, bitmap.size()));
  HANDLE_ERROR(cudaBindTexture(NULL, texture_input,
    data.device_input, bitmap.size()));
  HANDLE_ERROR(cudaBindTexture(NULL, texture_output,
    data.device_output, bitmap.size()));

  float *heaters_grid = new float[bitmap.size()];
  for (int i = 0; i < DIM * DIM; i++) {
    heaters_grid[i] = 0.0f;

    int x = i % DIM;
    int y = i / DIM;

    if ((x > 300) && (x < 600) && (y > 310) && (y < 601))
      heaters_grid[i] = MAX_TEMPERATURE;

    heaters_grid[100 + 100 * DIM] = (MIN_TEMPERATURE + MAX_TEMPERATURE) / 2;
    heaters_grid[100 + 700 * DIM] = MIN_TEMPERATURE;
    heaters_grid[300 + 300 * DIM] = MIN_TEMPERATURE;
    heaters_grid[700 + 200 * DIM] = MIN_TEMPERATURE;

    for (int k = 800; k < 900; k++) {
      for (int j = 400; j < 500; j++)
        heaters_grid[j + k * DIM] = MIN_TEMPERATURE;
    }
  }

  HANDLE_ERROR(cudaMemcpy(data.device_heaters, heaters_grid,
    bitmap.size(), cudaMemcpyHostToDevice));

  for (int j = 800; j < DIM; j++)
    for (int i = 0; i < 200; i++)
      heaters_grid[i + j * DIM] = MAX_TEMPERATURE;

  HANDLE_ERROR(cudaMemcpy(data.device_heaters, heaters_grid,
    bitmap.size(), cudaMemcpyHostToDevice));

  delete [] heaters_grid;

  bitmap.animate((void (*)(void *, int)) animate_display,
    (void (*)(void *)) animate_exit);

  return 0;
}


void animate_display(Data *data, int clock)
{
  float compute_time;
  
  HANDLE_ERROR(cudaEventRecord(data->start, 0));

  AnimateBitmap *bitmap = data->bitmap;

  dim3 blocks_per_grid(DIM / 16, DIM / 16);
  dim3 threads_per_block(16, 16);
  volatile bool flag_IO = true;

  for (int i = 0; i < TIME_STEPS_PER_FRAME; i++) {
    float *input_ptr, *output_ptr;
    
    if (flag_IO == true) {
      input_ptr = data->device_input;
      output_ptr = data->device_output;
    } else {
      input_ptr = data->device_output;
      output_ptr = data->device_input;
    }
    
    maintain_heaters<<<blocks_per_grid, threads_per_block>>>(
      input_ptr);
    temperature_update<<<blocks_per_grid, threads_per_block>>>(
      output_ptr, flag_IO);

    flag_IO = !flag_IO;
  }

  float_to_color<<<blocks_per_grid, threads_per_block>>>(
    data->device_input, data->device_bitmap);
  
  HANDLE_ERROR(cudaMemcpy(bitmap->pointer(), data->device_bitmap,
    bitmap->size(), cudaMemcpyDeviceToHost));

  HANDLE_ERROR(cudaEventRecord(data->stop, 0));
  HANDLE_ERROR(cudaEventSynchronize(data->stop));
  HANDLE_ERROR(cudaEventElapsedTime(&compute_time,
    data->start, data->stop));
  data->compute_time += compute_time;
  
  ++data->count_frames;

  printf("Mean compute time per frame: %.1f ms\n",
    data->compute_time / data->count_frames);
}


void animate_exit(Data *data)
{
  HANDLE_ERROR(cudaUnbindTexture(texture_heaters));
  HANDLE_ERROR(cudaUnbindTexture(texture_input));
  HANDLE_ERROR(cudaUnbindTexture(texture_output));

  HANDLE_ERROR(cudaFree(data->device_heaters));
  HANDLE_ERROR(cudaFree(data->device_input));
  HANDLE_ERROR(cudaFree(data->device_output));
  
  HANDLE_ERROR(cudaEventDestroy(data->start));
  HANDLE_ERROR(cudaEventDestroy(data->stop));
}


__global__ void maintain_heaters(float *ptr)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;
  int current_idx = x + y * blockDim.x * gridDim.x;

  float heat_source = tex1Dfetch(texture_heaters, current_idx);
  if (heat_source != 0)
    ptr[current_idx] = heat_source;
}


__global__ void temperature_update(float *ptr, bool flag_IO)
{
  int x = threadIdx.x + blockIdx.x * blockDim.x;
  int y = threadIdx.y + blockIdx.y * blockDim.y;
  int current_idx = x + y * blockDim.x * gridDim.x;

  int left_idx = current_idx - 1;
  if (x == 0)
    ++left_idx;
  int right_idx = current_idx + 1;
  if (x == DIM - 1)
    --right_idx;
  int upper_idx = current_idx - DIM;
  if (y == 0)
    upper_idx += DIM;
  int lower_idx = current_idx + DIM;
  if (y == DIM - 1)
    lower_idx -= DIM;

  float current, left, right, upper, lower;

  if (flag_IO) {
    current = tex1Dfetch(texture_input, current_idx);
    left = tex1Dfetch(texture_input, left_idx);
    right = tex1Dfetch(texture_input, right_idx);
    upper = tex1Dfetch(texture_input, upper_idx);
    lower = tex1Dfetch(texture_input, lower_idx);
  } else {
    current = tex1Dfetch(texture_output, current_idx);
    left = tex1Dfetch(texture_output, left_idx);
    right = tex1Dfetch(texture_output, right_idx);
    upper = tex1Dfetch(texture_output, upper_idx);
    lower = tex1Dfetch(texture_output, lower_idx);
  }

  float gradient = left + right + upper + lower - 4 * current;
  ptr[current_idx] = current + SPEED * gradient;
}
