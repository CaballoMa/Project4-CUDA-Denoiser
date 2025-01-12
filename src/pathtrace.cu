#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1

#define GAUSS_ON_ATROUS_OFF 0
#define AVOID_EDGE 1
#define SHOW_POS_BUFFER 0
#define SHOW_NOR_BUFFER 0

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
    getchar();
#  endif
    exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

__global__ void gbufferToPBO(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        float timeToIntersect = gBuffer[index].t * 255.0;

        pbo[index].w = 0;
        pbo[index].x = timeToIntersect;
        pbo[index].y = timeToIntersect;
        pbo[index].z = timeToIntersect;
    }
}

__global__ void gbufferToPBONormal(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 nor = gBuffer[index].nor * 255.f;
        pbo[index].w = 0;
        pbo[index].x = abs(nor.x);
        pbo[index].y = abs(nor.y);
        pbo[index].z = abs(nor.z);
    }
}

__global__ void gbufferToPBOPosition(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pos = gBuffer[index].pos * 25.5f;
        pbo[index].w = 0;
        pbo[index].x = abs(pos.x);
        pbo[index].y = abs(pos.y);
        pbo[index].z = abs(pos.z);

    }
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
static GBufferPixel* dev_gBuffer = NULL;
// TODO: static variables for device memory, any extra info you need, etc
static glm::vec3* dev_denoised_image = NULL;
static glm::vec3* dev_denoised_buffer = NULL;
static Geom* lights = NULL;

void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

  	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

  	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
  	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
  	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
  	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    cudaMalloc(&dev_gBuffer, pixelcount * sizeof(GBufferPixel));

    // TODO: initialize any extra device memeory you need
    cudaMalloc(&dev_denoised_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_denoised_image, 0, pixelcount * sizeof(glm::vec3));
    cudaMalloc(&dev_denoised_buffer, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_denoised_buffer, 0, pixelcount * sizeof(glm::vec3));

    cudaMalloc(&lights, scene->lightNum * sizeof(Geom));
    cudaMemcpy(lights, scene->lights.data(), scene->lights.size() * sizeof(Geom), cudaMemcpyHostToDevice);

    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
    cudaFree(dev_gBuffer);
    // TODO: clean up any extra device memory you created
    cudaFree(dev_denoised_image);
    cudaFree(dev_denoised_buffer);
    cudaFree(lights);
    checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

		segment.ray.origin = cam.position;
    segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
			);

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
	)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 nor;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				nor = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = nor;
		}
	}
}

__global__ void shadeSimpleMaterials (
  int iter
  , int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
    , Geom* lights
    , int lightNum
	)
{
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num_paths)
  {
    ShadeableIntersection intersection = shadeableIntersections[idx];
    PathSegment segment = pathSegments[idx];
    if (segment.remainingBounces == 0) {
      return;
    }

    if (intersection.t > 0.0f) { // if the intersection exists...
      segment.remainingBounces--;
      // Set up the RNG
      thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, segment.remainingBounces);

      Material material = materials[intersection.materialId];
      glm::vec3 materialColor = material.color;

      // If the material indicates that the object was a light, "light" the ray
      if (material.emittance > 0.0f) {
        segment.color *= (materialColor * material.emittance);
        segment.remainingBounces = 0;
      }
      else {
        segment.color *= materialColor;
        glm::vec3 intersectPos = intersection.t * segment.ray.direction + segment.ray.origin;
        scatterRay(segment, intersectPos, intersection.surfaceNormal, material, rng, lights, lightNum);
      }
    // If there was no intersection, color the ray black.
    // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
    // used for opacity, in which case they can indicate "no opacity".
    // This can be useful for post-processing and image compositing.
    } else {
      segment.color = glm::vec3(0.0f);
      segment.remainingBounces = 0;
    }

    pathSegments[idx] = segment;
  }
}

__global__ void generateGBuffer (
  int num_paths,
  ShadeableIntersection* shadeableIntersections,
	PathSegment* pathSegments,
  GBufferPixel* gBuffer) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num_paths)
  {
    gBuffer[idx].t = shadeableIntersections[idx].t;
    gBuffer[idx].nor = shadeableIntersections[idx].surfaceNormal;
    gBuffer[idx].pos = pathSegments[idx].ray.origin + pathSegments[idx].ray.direction * gBuffer[idx].t;
  }
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(int frame, int iter) {
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

    ///////////////////////////////////////////////////////////////////////////

    // Pathtracing Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray must carry at minimum a (ray, color) pair,
    //   * where color starts as the multiplicative identity, white = (1, 1, 1).
    //   * This has already been done for you.
    // * NEW: For the first depth, generate geometry buffers (gbuffers)
    // * For each depth:
    //   * Compute an intersection in the scene for each path ray.
    //     A very naive version of this has been implemented for you, but feel
    //     free to add more primitives and/or a better algorithm.
    //     Currently, intersection distance is recorded as a parametric distance,
    //     t, or a "distance along the ray." t = -1.0 indicates no intersection.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //   * Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    //     * Note that you can't really use a 2D kernel launch any more - switch
    //       to 1D.
    //   * Shade the rays that intersected something or didn't bottom out.
    //     That is, color the ray by performing a color computation according
    //     to the shader, then generate a new ray to continue the ray path.
    //     We recommend just updating the ray's PathSegment in place.
    //     Note that this step may come before or after stream compaction,
    //     since some shaders you write may also cause a path to terminate.
    // * Finally:
    //     * if not denoising, add this iteration's results to the image
    //     * TODO: if denoising, run kernels that take both the raw pathtraced result and the gbuffer, and put the result in the "pbo" from opengl

	generateRayFromCamera <<<blocksPerGrid2d, blockSize2d >>>(cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

  // Empty gbuffer
  cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

	// clean shading chunks
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

  bool iterationComplete = false;
	while (!iterationComplete) {

	// tracing
	dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
	computeIntersections <<<numblocksPathSegmentTracing, blockSize1d>>> (
		depth
		, num_paths
		, dev_paths
		, dev_geoms
		, hst_scene->geoms.size()
		, dev_intersections
		);
	checkCUDAError("trace one bounce");
	cudaDeviceSynchronize();

  if (depth == 0) {
    generateGBuffer<<<numblocksPathSegmentTracing, blockSize1d>>>(num_paths, dev_intersections, dev_paths, dev_gBuffer);
  }

	depth++;

  shadeSimpleMaterials<<<numblocksPathSegmentTracing, blockSize1d>>> (
    iter,
    num_paths,
    dev_intersections,
    dev_paths,
    dev_materials,
    lights,
    hst_scene->lightNum
  );
  iterationComplete = depth == traceDepth;
	}

  // Assemble this iteration and apply it to the image
  dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather<<<numBlocksPixels, blockSize1d>>>(num_paths, dev_image, dev_paths);

    ///////////////////////////////////////////////////////////////////////////

    // CHECKITOUT: use dev_image as reference if you want to implement saving denoised images.
    // Otherwise, screenshots are also acceptable.
    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

    checkCUDAError("pathtrace");
}

__global__ void ATrousDenoise(float c_phi, float n_phi, float p_phi, glm::ivec2 resolution, GBufferPixel* gBuffer, int stepWidth,
    glm::vec3* origin_image, glm::vec3* denoised_image)
{
    int x = blockDim.x * blockIdx.x + threadIdx.x;
    int y = blockDim.y * blockIdx.y + threadIdx.y;
    if (x >= resolution.x || y >= resolution.y) return;

    int idx = x + y * resolution.x;

    glm::vec3 cval = origin_image[idx];
    glm::vec3 nval = gBuffer[idx].nor;
    glm::vec3 pval = gBuffer[idx].pos;
    
    float cum_w = 0.0f;
    glm::vec3 sum = glm::vec3(0.f);

    static float kernel[5][5] = {
        0.00296902, 0.0133062, 0.0219382, 0.0133062, 0.00296902,
        0.0133062, 0.0596343, 0.0983203, 0.0596343, 0.0133062,
        0.0219382, 0.0983203, 0.162103, 0.0983203, 0.0219382,
        0.0133062, 0.0596343, 0.0983203, 0.0596343, 0.0133062,
        0.00296902, 0.0133062, 0.0219382, 0.0133062, 0.00296902,
    };
    for (int i = -2; i < 2; i++) {
        for (int j = -2; j < 2; j++) {
            glm::ivec2 uv;
            uv.x = x + i * stepWidth;
            uv.y = y + j * stepWidth;
            uv = glm::clamp(uv, glm::ivec2(0, 0), glm::ivec2(resolution.x - 1, resolution.y - 1));

            int idxtmp = uv.x + uv.y * resolution.x;
            glm::vec3 ctmp = origin_image[idxtmp];
            float weight = 1.0f;

#if AVOID_EDGE

            glm::vec3 t = cval - ctmp;
            float dist2 = glm::dot(t, t);
            float c_w = glm::min(glm::exp(-dist2 / c_phi), 1.0f);

            glm::vec3 ntmp = gBuffer[idxtmp].nor;
            t = nval - ntmp;
            dist2 = glm::max((glm::dot(t, t) / (stepWidth * stepWidth)), 0.0f);
            dist2 = glm::dot(t, t);
            float n_w = glm::min(glm::exp(-dist2 / n_phi), 1.0f);

            glm::vec3 ptmp = gBuffer[idxtmp].pos;
            t = pval - ptmp;
            dist2 = glm::dot(t, t);
            float p_w = glm::min(glm::exp(-dist2 / p_phi), 1.0f);

            weight = c_w * n_w * p_w;

#endif
            float curKernel = kernel[i+2][j+2];
            sum += ctmp * weight * curKernel;
            cum_w += weight * curKernel;
        }
    }
    denoised_image[idx] = sum / cum_w;
}

__global__ void GaussDenoise(glm::ivec2 resolution, GBufferPixel* gBuffer,
    float c_phi, float n_phi, float p_phi, int filtersize, glm::vec3* origin_image, glm::vec3* denoised_image)
{
    int x = blockDim.x * blockIdx.x + threadIdx.x;
    int y = blockDim.y * blockIdx.y + threadIdx.y;

    if (x >= resolution.x || y >= resolution.y) return;

    int idx = x + y * resolution.x;

    glm::vec3 cval = origin_image[idx];
    glm::vec3 nval = gBuffer[idx].nor;
    glm::vec3 pval = gBuffer[idx].pos;

    glm::vec3 sum = glm::vec3(0.f);
    float cum_w = 0.0f;

    int bound = (filtersize - 1) / 2;
    int s = filtersize / 6;

    for (int i = -bound; i <= bound; ++i)
    {
        for (int j = -bound; j <= bound; ++j)
        {
            glm::ivec2 uv;
            uv.x = x + i;
            uv.y = y + j;

            float weight = 1.0f;

            if (uv.x >= 0 && uv.x < resolution.x && uv.y >= 0 && uv.y <= resolution.y)
            {
                int idxtmp = uv.x + uv.y * resolution.x;
                glm::vec3 ctmp = origin_image[idxtmp];
                
#if AVOID_EDGE

                glm::vec3 t = cval - ctmp;
                float dist2 = glm::dot(t, t);
                float c_w = glm::min(glm::exp(-dist2 / c_phi), 1.0f);

                glm::vec3 ntmp = gBuffer[idxtmp].nor;
                t = nval - ntmp;
                dist2 = glm::max(glm::dot(t, t), 0.0f);
                float n_w = glm::min(glm::exp(-dist2 / n_phi), 1.0f);

                glm::vec3 ptmp = gBuffer[idxtmp].pos;
                t = pval - ptmp;
                dist2 = glm::dot(t, t);
                float p_w = glm::min(glm::exp(-dist2 / p_phi), 1.0f);

                weight = c_w * n_w * p_w;

#endif
                float curKernel = (1.f / (2.f * PI * s * s)) * exp(-(i * i + j * j) / (2.f * s * s));
                sum += ctmp * weight * curKernel;
                cum_w += weight * curKernel;
            }
        }
    }
    denoised_image[idx] = sum / cum_w;
}

void denoise(float c_phi, float n_phi, float p_phi, float filterSize)
{
    Camera& cam = hst_scene->state.camera;
    glm::ivec2 resolution = cam.resolution;

    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
        (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
        (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    cudaMemcpy(dev_denoised_buffer, dev_image, resolution.x * resolution.y * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);

#if GAUSS_ON_ATROUS_OFF
        GaussDenoise << <blocksPerGrid2d, blockSize2d >> > (resolution, dev_gBuffer, c_phi, n_phi, p_phi, filterSize, dev_denoised_buffer, dev_denoised_image);
#else 
        for (int stepWidth = 1; 4 * stepWidth < filterSize; stepWidth *= 2)
        {
            ATrousDenoise << <blocksPerGrid2d, blockSize2d >> > (c_phi, n_phi, p_phi, resolution, dev_gBuffer, stepWidth, dev_denoised_buffer, dev_denoised_image);
            cudaDeviceSynchronize();
            std::swap(dev_denoised_buffer, dev_denoised_image);
        }
#endif
    cudaMemcpy(hst_scene->state.image.data(), dev_denoised_image, resolution.x * resolution.y * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
}

// CHECKITOUT: this kernel "post-processes" the gbuffer/gbuffers into something that you can visualize for debugging.
void showGBuffer(uchar4* pbo) {
    const Camera &cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // CHECKITOUT: process the gbuffer results and send them to OpenGL buffer for visualization
#if SHOW_POS_BUFFER
    gbufferToPBO_Position << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, dev_gBuffer);

#elif SHOW_NOR_BUFFER
    gbufferToPBO_Normal << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, dev_gBuffer);

#else
    gbufferToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, dev_gBuffer);
#endif
}

void showImage(uchar4* pbo, int iter) {
const Camera &cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, iter, dev_image);
}

void showDenoisedImage(uchar4* pbo, int iter) {
    const Camera& cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
        (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
        (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // Send results to OpenGL buffer for rendering
    sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_denoised_image);
}
