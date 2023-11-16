// Compile with nvcc 2dconvec.cu -lcublas -arch sm_13
// -lcublas because we're using cublas
// -arch sm_13 to alert the compiler that we're using a GPU that supports
// float-precision.
// tab spacing = 4

// NOTICE
// This file was stored by David Sanchez in 2023, based on a recovered hard-drive.  The code almost certainly dates to 2010 (earlier/later).
// I think I wrote this based on Matlab code by Grady Wright and Greg Barnett, under the supervision of Dave Yuen (and advice + comments from many).
// That said, I do not recall exactly when or under what conditions this was written and it may have been given to me.
// In whole, in part, or in derivative this code forms the basis of some papers, but I've lost track of which ones.  I don't even know whether this
// is the most up-to-date such code.
//
// Sincere apologies.  Good luck.


#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <time.h>
#include <string.h>
#include "cublas.h"

// Parameters.  These may change from run-to-run
#define M (500) // vertical dimension of the temperature array
#define RA (100000000.0) // Rayleigh number
#define XF (2)	// Aspect ratio for the temperature array
#define DBG_ON 0 // Used to toggle writing to the debug file.  Slow!
#define PRINTVORT (1) // Write the vorticity to file
#define PRINTVEL (1) // Write to the convecvelocity.dat file.
#define PRINTSTREAM (1) // Write the streamfunction to file.
#define PRINTT (1) // Write the temperature data to file
#define PRINTNU (1) // Write the Nusselt number data to file.
#define STARTSTEP (0) // First step.  Useful if filenames are to be consistent
					  // and INPUTT is on
#define ENDSTEP (1000000) // Last timestep to compute.  If
						 // ENDSTEP%FRAMSIZE != 0 don't expect this to be nice
#define INPUTT (0) // Read the value of T from input2d.bin
#define INPUTT32 (0) // Read the value of T from input2d32.bin, filled with floats instead of uint8_t
#define BSNAME "ra108_1000x498_jul27_" // for filenames.  BE CAREFUL WITH IT

// Constants.  Stability cannot be assured if these values are altered.
//#define N (XF*(M-1)+1) // horizontal dimension of temperature array
#define N (1000)
#define DX (1/(M - 1.0)) // x and z-dimensional mesh spacing
#define DX2 (DX*DX) // DX^2, for saving a few computations.
#define OMEGACOEFF (-((DX*DX)*(DX*DX))*RA) // Used on every timestep

#define PI 3.1415926535897932384626433832795028841968 // Precision here is arbitrary and may be traded
							 // for performance if context allows
#define DT_START 0.000000000000005 //timestep width.  Needs to be small to
								    //guide the model through high Ra runs.


#define FRAMESIZE (DX2/4.0) // How many iterations between saves
// flatten a 2D grid with 1D blocks into a vector.  The functionality
// could be extended to perform pointer arithmetic, but that's not necessary
// in this code.
//
//  Invoked grid geometry
//  (2D grid with 1D blocks)
//
//  |---|---|---|
//  |1,1|1,2|1,3|
//  |---|---|---|
//  |2,1|2,2|2,3|  ==>  1,1 1,2 1,3 2,1 2,2 ...
//  |---|---|---|
//  |3,1|3,2|3,3|
//  |---|---|---|


#define THREADID (((gridDim.x)*(blockIdx.y) + (blockIdx.x))*(blockDim.x) + (threadIdx.x))

// It is possible to alternate between 2D row-major and column-major formats by
// taking transposes.
#define TPOSE(i,j,ld) ((j)*(ld) + (i))

// Simplify device-side array allocation, assumes all types are float.
#define CUALLOC(elements, name) float* name; custat = cublasAlloc(elements, sizeof(float), (void**)&name); if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n")

// Simplify calling G, since many of the arguments are assured
#define SHORTG(input, compute, save, frames) G(input, d_Tbuff, d_DxT, d_y, d_u, d_v, d_psi, d_omega, d_dsc, d_dsr, d_ei, d_dt, save, h_T, compute, frames, tstep)

// Define a global N-by-N array h_DBG, for debugging purposes.
float h_DBG[N*N];

//-----------------------------------------------------------------------------
//=============================================================================
//									KERNELS
//=============================================================================
//-----------------------------------------------------------------------------

//=============================================================================
//							   ElementMultOmega
//=============================================================================
// Performs elementwise matrix multiplication on matrices shaped like omega,
// returning the result in A.
__global__ void ElemMultOmega(float* A, float* B) {
	if(THREADID < (M-2)*(N-2) ) {
		A[THREADID] = A[THREADID]*B[THREADID];
	}
	return;
}

//=============================================================================
//								 ElementMultT
//=============================================================================
// Performs elementwise matrix multiplication on matrices shaped like T,
// putting the result in A.
__global__ void ElemMultT(float* A, float* B) {
	if(THREADID < (M-2)*(N)) {
		A[THREADID] = A[THREADID]*B[THREADID];
	}
	return;
}

//=============================================================================
//								 ElementMultNu
//=============================================================================
// Performs elementwise matrix multiplication on matrices shaped like d_nutop,
// putting the result in A.
__global__ void ElemMultNu(float* A, float* B) {
	if(THREADID < N) {
		A[THREADID] = A[THREADID]*B[THREADID];
	}
	return;
}

//=============================================================================
//								    SubOne
//=============================================================================
// Subtracts 1.0 from every element in a vector (floats) of length N
__global__ void SubOne(float* A) {
	if(THREADID < N) {
		A[THREADID] = A[THREADID] - 1.0;
	}
	return;
}

//=============================================================================
//								    AddOne
//=============================================================================
// Adds 1.0 from every element in a vector (floats) of length N
__global__ void AddOne(float* A) {
	if(THREADID < N) {
		A[THREADID] = A[THREADID] + 1.0;
	}
	return;
}

//=============================================================================
//								    AddX
//=============================================================================
// Adds x from every element in a vector (floats) of length (M-2)*N
__global__ void AddX(float* A, float x) {
	if(THREADID < (M-2)*N) {
		A[THREADID] = A[THREADID] + x;
	}
	return;
}

//=============================================================================
//								   Updatedt
//=============================================================================
// Adaptive update rule for dt.  d_dt (a device-side one-element array) should
// be passed as dt, whereas ptru and ptrv point (1-indexed) to vectors u and v.
// The current value of dt[0] will be overwritten. Can be called with a 1D
// grid containing a single 1D block with one thread.
__global__ void Updatedt(int ptru, float* u, int ptrv, float* v, float* dt) {
	if( (threadIdx.x + blockIdx.x*blockDim.x) == 0) {
		dt[0] = max(abs(u[ptru - 1]),abs(v[ptrv - 1]));
		dt[0] = min(DX/dt[0],DX2/4.0);
	}
	return;
}
//-----------------------------------------------------------------------------
//=============================================================================
//							  Host-Side Routines
//=============================================================================
//-----------------------------------------------------------------------------

//=============================================================================
//								   WriteT
//=============================================================================
// WriteT will write 255 times the uint8 equivalent of the float x.  Why?
// Because this is the perfect format for .bob files.
void WriteT(float x, FILE* outfile) {
	uint8_t savnum = 255*x;
	// C typecasts down by truncation, so adding 0.5 forces it to round.
	// Inverse for negatives.
	if(x >= 0) {
		savnum = (uint8_t)(255*x + 0.5);
	}
	else {
		savnum = (uint8_t)(255*x - 0.5);
	}
	fwrite(&savnum, 1, 1, outfile);
	return;
}
//=============================================================================
//                                 WriteT32
//=============================================================================
// WriteT will write T in IEEE 32-bit form
void WriteT32(float x, FILE* outfile) {
        fwrite(&x, 4, 1, outfile);
        return;
}


//=============================================================================
//								   PrintGPU
//=============================================================================
// Takes a matrix (of floats) on the GPU and prints it to file.
//void PrintGPU(float* f, int rows, int cols) {
//	cublasGetVector(rows*cols, sizeof(float), &f[0], 1, &h_DBG[0], 1);
//	for(int i = 0; i < rows; i++) {
//		for(int j = 0; j < cols; j++) {
//			fprintf(dbgfile, "%2.4f ", h_DBG[i*cols + j]);
//		}
//		fprintf(dbgfile, "\n");
//	}
//	return;
//}

//=============================================================================
//									NormalizeT
//=============================================================================
// Normalizes the values of T to [0,1] as a safeguard against explosion
void NormalizeT(float* T) {
	float maxval[1];
	float minval[1];
	cublasGetVector(1, sizeof(float), T + (cublasIsamax(N*(M-2), T, 1) - 1), 1, maxval, 1);
	cublasGetVector(1, sizeof(float), T + (cublasIsamin(N*(M-2), T, 1) - 1), 1, minval, 1);
	AddX<<<floor((N*(M-2))/256.0) + 1, 256>>>(T, -minval[0]);
	cublasSscal(N*(M-2), 1/(maxval[0] - minval[0]), T, 1);
	return;
}


//=============================================================================
//									NusseltCompute
//=============================================================================
// Returns the Nusselt number of the array T, which is pointed to in GPU space
float NusseltCompute(float* T, float* nutop, float* ztop, float* zbot, float* nubot, float* trnu) {
		float topsum, botsum;
		// Calculate the Nusselt number along the top of the array.
		// d_nutop is the last three rows of T, in inverse order,
		// with all 0s along the bottom.

		// Copy the last three rows of T into the first three rows of nutop
		cublasScopy(N, (T + (M-5)*N), 1, (nutop), 1);
		cublasScopy(N, (T + (M-4)*N), 1, (nutop + (N)), 1);
		cublasScopy(N, (T + (M-3)*N), 1, (nutop + (2*N)), 1);

		// Set the last row of nutop = 0.
		cublasSscal(N, 0.0, (nutop + (3*N)), 1);

		// nutop += -( 1 - ztop)
		// => nutop += ztop; nutop -= 1
		cublasSaxpy(4*N, 1.0, ztop, 1, nutop, 1);
		// Subtract 1 from every element in the array.  SubOne works on rows.
		SubOne<<<floor(N/256.0) + 1, 256>>>(nutop);
		SubOne<<<floor(N/256.0) + 1, 256>>>(nutop + N);
		SubOne<<<floor(N/256.0) + 1, 256>>>(nutop + 2*N);
		SubOne<<<floor(N/256.0) + 1, 256>>>(nutop + 3*N);

		// -(2/3)*row0 + 3*row1 - 6*row2 + (11/3)*row3
		// accumulate in the 0th row
		// scale the 0th row by -(2/3)
		cublasSscal(N, -(2.0/3.0), nutop, 1);
		// Add 3*row1
		cublasSaxpy(N, 3.0, (nutop + N), 1, nutop, 1);
		// Add - 6*row2
		cublasSaxpy(N, -6.0, (nutop + (2*N)), 1, nutop, 1);
		// Add (11/3)*row3
		cublasSaxpy(N, (11.0/3.0), (nutop + (3*N)), 1, nutop, 1);
		// Divide the array by 2*DX
		cublasSscal(4*N, 1/(2.0*DX), nutop, 1);
		// Elementwise multiplication with trnu
		ElemMultNu<<<floor(N/256.0) + 1, 256>>>(nutop, trnu);
		// Sum up the elements of row0, by performing a dot product with
		// a row that has been altered to be all 1s.
		// Empty row1, then add 1 to all its elements
		cublasSscal(N, 0.0, (nutop + N), 1);
		AddOne<<<floor(N/256.0) + 1, 256>>>(nutop + N);

		topsum = cublasSdot(N, nutop, 1, (nutop + N), 1)/(-XF);

		// Calculate the Nusselt number along the bottom of the array.
		// d_nubot's first row is all 1, and ith row is the i-1th row of d_T
		// Put the first row of T in nubot, then subtract to get 0, then AddOne
		cublasSscal(N, 0.0, nubot, 1);
		AddOne<<<floor(N/256.0) + 1, 256>>>(nubot);
		cublasScopy(N, T, 1, (nubot + N), 1);
		cublasScopy(N, (T + N), 1, (nubot + 2*N), 1);
		cublasScopy(N, (T + 2*N), 1, (nubot + 3*N), 1);

		// nubot += -( 1 - zbot)
		// => nubot += zbot; nubot -= 1
		cublasSaxpy(4*N, 1.0, zbot, 1, nubot, 1);
		// Subtract 1 from every element in the array.  SubOne works on rows.
		SubOne<<<floor(N/256.0) + 1, 256>>>(nubot);
		SubOne<<<floor(N/256.0) + 1, 256>>>(nubot + N);
		SubOne<<<floor(N/256.0) + 1, 256>>>(nubot + 2*N);
		SubOne<<<floor(N/256.0) + 1, 256>>>(nubot + 3*N);

		// -(11/3)*row0 + 6*row1 - 3*row2 + (2/3)*row3
		// accumulate in the 0th row
		// scale the 0th row by -(11/3)
		cublasSscal(N, -(11.0/3.0), nubot, 1);
		// Add 6*row1
		cublasSaxpy(N, 6.0, (nubot + N), 1, nubot, 1);
		// Add -3*row2
		cublasSaxpy(N, -3.0, (nubot + (2*N)), 1, nubot, 1);
		// Add (2/3)*row3
		cublasSaxpy(N, (2.0/3.0), (nubot + (3*N)), 1, nubot, 1);
		// Divide the array by 2*DX
		cublasSscal(4*N, 1/(2.0*DX), nubot, 1);
		// Elementwise multiplication with trnu
		ElemMultNu<<<floor(N/256.0) + 1, 256>>>(nubot, trnu);
		// Sum up the elements of row0, by performing a dot product with
		// a row that has been altered to be all 1s.
		// The second row of nutop has already been set up for this.
		botsum = cublasSdot(N, nubot, 1, (nutop + N), 1)/(-XF);

		return(topsum);
}
//=============================================================================
//									  Dz
//=============================================================================
// Finite-difference approximation to the first derivative with respect to z of
// a matrix shaped like T.  Execution forks if f is known to be psi.  Uses only
// row manipulations and the subtraction of 1 from each element of a vector. To
// extract a row, cublas routines are used.  The elements of the first column
// are separated in memory by N elements, so the initial elements of each row
// are likewise separated.  The individual elements of a single row are
// separated in memory by 1 element.

void Dz(float* f, int is_it_psi, float* y) {
	// yrows[i] = frows[i + 1] - frows[i - 1]
	// Move all but the first two rows of f into the interior rows of y.
	// The end of one row is one element away from the beginning of the next,
	// so adjacent rows are laid out in memory identically to a vector.
	cublasScopy(N*(M-4), (f + (2*N)), 1, (y + N), 1);
	// Subtract all but the last two rows of f.
	cublasSaxpy(N*(M-4), -1.0, f, 1, (y + N), 1);

	if(is_it_psi == 1) {
		// yrows[0] = frows[1]
		// Move the second row of f into the first row of y
		cublasScopy(N, (f + N), 1, y, 1);
	}
	else {
		// yrows[0] = frows[1] - 1
		// Move the second row of f into the first row of y
		cublasScopy(N, (f + N), 1, y, 1);
		// Subtract 1 from every element in the first row of y.
		SubOne<<<floor(N/256.0) + 1, 256>>>(y);

	}

	// yrows[M-3] = -frows[M-4]
	// Copy the second-to-last row of f into the last row of y
	cublasScopy(N, (f + ((M - 4)*N)), 1, (y + (M - 3)*N), 1);
	// Scale by -1.0
	cublasSscal(N, -1.0, (y + (M - 3)*N), 1);
	// Scale y by 1/(2*DX)
	cublasSscal(N*(M-2), 1.0/(2.0*DX), y, 1);
	return;
}

//=============================================================================
//									  Dzz
//=============================================================================
// Finite-difference approximation to the second derivative with respect to z
// of a  T-shaped array.  Uses only row manipulations and the addition of 1 to
// each element of a vector.  To extract a row, cublas routines are used.  The
// elements of the first column are separated in memory by N elements, so the
// initial elements of each row are likewise separated.  The individual
// elements of a single row are separated in memory by 1 element.

void Dzz(float* f, float* y) {
	// yrows[i] = frows[i - 1] - 2*frows[i] + frows[i + 1]
	// Move all but the last two rows of f into the interior rows of y.
	cublasScopy(N*(M-4), f, 1, (y + N), 1);

	// Subtract 2* the interior rows of f
	cublasSaxpy(N*(M-4), -2.0, (f + N), 1, (y + N), 1);

	// Add all but the first two rows of f.
	cublasSaxpy(N*(M-4), 1.0, (f + (2*N)), 1, (y + N), 1);

	// yrows[0] = 1 - 2*frows[0] + frows[1]
	// Copy the first row of f into the first row of y
	cublasScopy(N, f, 1, y, 1);

	// scale by -2
	cublasSscal(N, -2.0, y, 1);

	// add the second row of f
	cublasSaxpy(N, 1.0, (f + N), 1, y, 1);

	// Add 1 to every element in the first row of y.
	AddOne<<<floor(N/256.0) + 1, 256>>>(y);

	// yrows[M-3] = frows[M-4] - 2*frows[M-3]
	// move the second-to-last row of f into the last row of y
	cublasScopy(N, (f + (M - 4)*N), 1, (y + (M - 3)*N), 1);
	// subtract 2* the last row of f
	cublasSaxpy(N, -2.0, (f + (M - 3)*N), 1, (y + (M - 3)*N), 1);
	// Scale y by 1/DX2
	cublasSscal((M-2)*N, (1.0/DX2), y, 1);
	return;
}

//=============================================================================
//									  Dx
//=============================================================================
// Finite difference approximation to the first derivative with
// respect to x of a T-shaped matrix.  Forks if f is known to be psi. Uses only
// column manipulations and assumes all matrices are in row-major.  To extract
// a column, cublas routines are used.  If the beginning of an array is at f,
// then the elements of the first row (start of each column) are separated by
// one element, and each element within a column is separated by the length
// of a row, N.

void Dx(float* f, int is_it_psi, float* y) {
	// ycols[i] = fcols[i+1] - fcols[i-1], interior cols
	// Copy all but the first two columns of f into the interior columns of y.
	// Copy row-by-row instead of column-by-column, since Dcopy is optimized
	// for longer vectors.

	for(int i = 0; i < M - 2; i++) {
		cublasScopy((N-2), (f + i*N) + 2, 1, (y + i*N) + 1, 1);
	}
	// Subtract the block corresponding to all but the last two columns of f.
	for(int i = 0; i < M - 2; i++) {
		cublasSaxpy((N-2), -1.0, (f + i*N), 1, (y + i*N) + 1, 1);
	}

	if(is_it_psi == 1) {
		// ycols[0] = 6*fcols[1] - 3*fcols[2] + (2/3)*fcols[3]
		// Begin by copying the second column of f into the first column of y
		cublasScopy((M-2), (f + 1), N, y, N);
		// Scale it by a factor of 6
		cublasSscal((M-2), 6.0, y, N);
		// Subtract the third column of 3*f
		cublasSaxpy((M-2), -3.0, (f + 2), N, y, N);
		// Add the fourth column of (2/3)*f
		cublasSaxpy((M-2), (2.0/3.0), (f + 3), N, y, N);

		//ycols[N-1] = -6*fcols[N-2] + 3*fcols[N-3] - (2/3)*fcols[N-4]
		// Copy the second-to-last column of f into the last column of y
		cublasScopy((M-2), (f + (N - 2)), N, (y + (N - 1)), N);
		// Scale it by a factor of -6
		cublasSscal((M-2), -6.0, (y + (N - 1)), N);
		// Add the third-to-last column of 3*fcols[N-3]
		cublasSaxpy((M-2), 3.0, (f + (N - 3)), N, (y + (N - 1)), N);
		// Subtract the fourth-to-last column of (2/3)*f[N-4]
		cublasSaxpy((M-2), -(2.0/3.0), (f + (N - 4)), N, (y + (N - 1)), N);
	}
	else {
		// outside columns = 0
		cublasSscal((M-2), 0.0, y, N);
		cublasSscal((M-2), 0.0, (y + (N - 1)), N);

	}

	// Scale y by (1/(2*DX))
	cublasSscal(N*(M-2), (1.0/(2.0*DX)), y, 1);
	return;
}

//=============================================================================
//									  Dxx
//=============================================================================
// Finite-difference approximation to the second derivative with
// respect to x of a T-shaped matrix.  The input is always going to be a temp-
// erature array.  Uses only column manipulations and assumes all matrices are
// in row-major.  To extract a column, cublas routines are used.  If the
// beginning of an array is at f, then the elements of the first row (start of
// each column) are separated by one element, and each element within a column
// is separated by the length of a row, N.

void Dxx(float* f, float* y) {
	// ycols[i] = fcols[i-1] - 2*fcols[i] + fcols[i+1], interior columns
	// copy f into y
	cublasScopy(N*(M-2), f, 1, y, 1);
	// scale by -2
	cublasSscal(N*(M-2), -2.0, y, 1);
	// Add the block corresponding to all but the last two columns of f.
	for(int i = 0; i < M-2; i++) {
		cublasSaxpy((N-2), 1.0, (f + i*N), 1, (y + i*N) + 1, 1);
	}
	// Add the block corresponding to all but the first two columns of f.
	for(int i = 0; i < M-2; i++) {
		cublasSaxpy((N-2), 1.0, (f + i*N) + 2, 1, (y + i*N) + 1, 1);
	}

	// ycols[0] = -2*fcols[0] + 2*fcols[1]
	// Copy the first column of f into the first column of y.
	cublasScopy((M-2), f, N, y, N);
	// Scale the first column of y by -2.0
	cublasSscal((M-2), -2.0, y, N);
	// Add 2* the second column of f.
	cublasSaxpy((M-2), 2.0, (f + 1), N, y, N);

	// ycols[N-1] = -2*fcols[N-1] + 2*fcols[N-2]
	// Move the last column of f into the last column of y
	cublasScopy((M-2), (f + (N - 1)), N, (y + (N - 1)), N);
	// Scale by -2.0
	cublasSscal((M-2), -2.0, (y + (N - 1)), N);
	// add 2* the second-to-last column of f.
	cublasSaxpy((M-2), 2.0, (f + (N - 2)), N, (y + (N - 1)), N);

	// Scale y by 1/(DX^2)
	cublasSscal(N*(M-2), 1.0/(DX2), y, 1);
	return;
}



//=============================================================================
//									   G
//=============================================================================
// Computes the RK1 approximation using finite difference method, storing the
// result in output
void G(float* f,
	   float* Tbuff,
	   float* DxT,
	   float* y,
	   float* u,
	   float* v,
	   float* psi,
	   float* omega,
	   float* dsc,
	   float* dsr,
	   float* ei,
	   float* dt,
	   float* output,
	   float* h_T,
	   int compute_velocity,
	   int frames,
	   int tstep) {

	// Define the grid dimensions
	dim3 grid(floor(N/16) + 1, floor((M-2)/16) + 1), block(256);

	// Define omega to be the interior columns of Dxf
	// Save Dx of f in DxT for later
	cublasScopy(N*(M-2), f, 1, DxT, 1);
	Dx(f, 0, DxT);

	// Copy the interior columns of DxT to omega
	for(int i = 0; i < M-2; i ++) {
		cublasScopy((N-2), (DxT + i*N)+1, 1, (omega + i*(N-2)), 1);
	}

	// Perform some matrix multiplications.  cublas assumes everything is in
	// column-major, so while we want to perform:
	// omega = dsc*omega
	// omega = omega*dsr
	// omega = omega.*ei
	// omega = dsc*omega
	// omega = omega*dsr
	// we observe that Transpose(A*B) = Transpose(B)*Transpose(A) to perform
	// these same manipulations while preserving row-major storage.
	// Omega has dimensions (M-2)xN, but cublas thinks this is Nx(M-2).
	// dsc and dsr are square..
	// Perform Transpose(omega) = Transpose(omega)*Transpose(dsc):
	//
	//					 _M-2_
	//					|	  |
	//				M-2	| dsc |
	//					|_____| ld = M-2
	//
	//		 _M-2_		 _M-2_
	//		|	  |		|	  |
	//		|	  |		|	  |
	//		|	  |		| new |
	//	 N-2|omega|	 N-2|omega|
	//		|	  |		|	  |
	//		|ld=N-2		|ld=N-2
	//		|_____|		|_____|
	// The call for cublasSgemm is ('n', 'n', m, n, k, alpha, A, lda, B, ldb,
	// beta, C, ldc), where A is m-by-k, B is k-by-n, and C is m-by-n.
	// Since A = C, k = n, so B is k-by-k.  B = dsc, so k=n=M-2 and m = N-2.
	cublasSgemm('n', 'n', N-2, M-2, M-2, 1.0, omega, N-2, dsc, M-2, 0.0, Tbuff, N-2 );
	cublasScopy((N-2)*(M-2), Tbuff, 1, omega, 1);

	// Perform Tranpose(dsr)*Transpose(omega), store in omega.
	//						 _M-2_
	//						|	  |
	//						|	  |
	//						| 	  |
	//					 N-2|omega|
	//						|	  |
	//						|ld=N-2
	//						|_____|
	//
	//		 ___N-2___		 _M-2_
	//		|		  |		|	  |
	//		|		  |		|	  |
	//		|		  |		| new |
	//	 N-2|	dsr   |	 N-2|omega|
	//		|		  |		|	  |
	//		|  ld=N-2 |		|ld=N-2
	//		|_________|		|_____|
	// since A is square, M = k = N-2, so n must be M-2.
	cublasSgemm('n', 'n', N-2, M-2, N-2, 1.0, dsr, N-2, omega, N-2, 0.0, Tbuff, N-2);
	cublasScopy((N-2)*(M-2), Tbuff, 1, omega, 1);

	// elementwise matrix multiplication, storing the result in omega
//DEBUG
	ElemMultOmega<<<grid, block>>>(omega, ei);

	// same Transpose(omega)*Transpose(dsc) operation as before
	cublasSgemm('n', 'n', N-2, M-2, M-2, 1.0, omega, N-2, dsc, M-2, 0.0, Tbuff, N-2);
	cublasScopy((N-2)*(M-2), Tbuff, 1, omega, 1);


	// same Transpose(dsr)*Transpose(omega) operation as before
	cublasSgemm('n', 'n', N-2, M-2, N-2, 1.0, dsr, N-2, omega, N-2, 0.0, Tbuff, N-2);
	cublasScopy((N-2)*(M-2), Tbuff, 1, omega, 1);

	if(PRINTVORT == 1 && frames > FRAMESIZE ) {
		char stringnum[25];
		float x;
		char vortname[100] = "Vort" BSNAME;
		sprintf(stringnum,"%d.bin",tstep);
		strcat(vortname,stringnum);
		// Open a stream for writing Vort data
		FILE *vortfile = fopen(vortname,"w");
		cublasGetVector((N-2)*(M-2), sizeof(float), omega, 1, h_T, 1);
		// We have to normalize vorticity, but its sign is very important.
		float maxx = h_T[0];
		float minx = h_T[0];
		for(int k = 0; k < (N-2)*(M-2); k++) {
			if(minx > h_T[k]) minx = h_T[k];
			if(maxx < h_T[k]) maxx = h_T[k];
		}
		for(int i = M-3; i > -1; i--) {
        	for(int j = 0; j < N-2; j++) {
				x = (float)h_T[i*(N-2)+j];
//				if(x < 0) x /= minx;
//				if(x > 0) x /= maxx;
//				x += 1.0;
//				x /= 2.0;
				WriteT32(h_T[i*(N-2)+j], vortfile);
			}
		}
		fclose(vortfile);
	}

	// Scale omega by -(DX^4)*(RA) = OMEGACOEFF
	cublasSscal((N-2)*(M-2), OMEGACOEFF, omega, 1);

	// interior columns of psi = (RA*DX^4)*omega
	// copy omega into the interior columns of psi
	// omega has rows of length N-2 instead of N

	for(int i = 0; i < M-2; i ++) {
		cublasScopy((N-2), (omega + i*(N-2)), 1, (psi + i*N)+1, 1);
	}

	// Write streamfunction to file
	if(PRINTSTREAM == 1 && frames > FRAMESIZE) {
		char stringnum[25];
		float x;
		char streamname[100] = "Stream" BSNAME;
		sprintf(stringnum,"%d.bin",tstep);
		strcat(streamname,stringnum);
		// Open a stream for writing streamfunction data
		FILE *streamfile = fopen(streamname,"w");
		cublasGetVector(N*(M-2), sizeof(float), psi, 1, h_T, 1);
		// We have to normalize vorticity, but its sign is very important.
		float maxx = h_T[0];
		float minx = h_T[0];
		for(int k = 0; k < N*(M-2); k++) {
			if(minx > h_T[k]) minx = h_T[k];
			if(maxx < h_T[k]) maxx = h_T[k];
		}
		for(int i = M-3; i > -1; i--) {
                        for(int j = 0; j < N; j++) {
                                x = (float)h_T[i*N+j];
                                if(x < 0) x /= minx;
                                if(x > 0) x /= maxx;
                                x += 1.0;
                                x /= 2.0;
                                WriteT32(x, streamfile);
                        }
                }
		fclose(streamfile);
	}
	// Velocity in the x-direction
	cublasScopy(N*(M-2), f, 1, u, 1);
	Dz(psi, 1, u);

	if(PRINTVEL == 1 && frames > FRAMESIZE) {
		char stringnum[25];
		float x;
		char vxname[100] = "Vx" BSNAME;
		sprintf(stringnum,"%d.bin",tstep);
		strcat(vxname,stringnum);
		// Open a stream for writing Vx data
		FILE *vxfile = fopen(vxname,"w");
		cublasGetVector(N*(M-2), sizeof(float), u, 1, h_T, 1);
                for(int i = M-3; i > -1; i--) {
                	for(int j = 0; j < N; j++) {
                        x = (float)h_T[i*N+j];
						fwrite(&x,4,1,vxfile);
                	}
                }
		fclose(vxfile);
        }

	// v is -Dxpsi, velocity in the z direction.
	// Place Dxpsi into v
	cublasScopy(N*(M-2), f, 1, v, 1);
	Dx(psi, 1, v);

        if(PRINTVEL == 1 && frames > FRAMESIZE) {
                char stringnum[25];
		float x;
                char vyname[100] = "Vy" BSNAME;
                sprintf(stringnum,"%d.bin",tstep);
                strcat(vyname,stringnum);
                // Open a stream for writing Vy data
                FILE *vyfile = fopen(vyname,"w");
                cublasGetVector(N*(M-2), sizeof(float), v, 1, h_T, 1);
                for(int i = M-3; i > -1; i--) {
                        for(int j = 0; j < N; j++) {
                        	x = (float)h_T[i*N+j];
                            fwrite(&x,4,1,vyfile);
                        }
                }
		fclose(vyfile);
        }

	// Change the sign of v.
	cublasSscal((M-2)*N, -1.0f, v, 1);
	// Store v in the z velocity file

	// If compute_velocity = 1, we need to update dt
	if(compute_velocity == 1) {
		// CublasIdamax returns 1-indexed pointers into the max element of a
		// float-precision vector
		Updatedt<<<1,1>>>(cublasIsamax(N*(M-2), u, 1), u, cublasIsamax(N*(M-2), v, 1), v, dt);
	}

	// Place Dxxf into y
	cublasScopy(N*(M-2), f, 1, y, 1);
	Dxx(f, y);

	// y = y + Dzzf
	// place Dzzf into Tbuff
	cublasScopy(N*(M-2), f, 1, Tbuff, 1);
	Dzz(f, Tbuff);

	// Add the elements of y and Tbuff, storing in y.
	cublasSaxpy(N*(M-2), 1.0, Tbuff, 1, y, 1);

	// u = u.*DxT, where .* denotes elementwise multiplication
	// Perform the elentwise multiplication, storing in u
	ElemMultT<<<grid, block>>>(u,DxT);

	// y = y + u
	// Add y and u, storing the result in y
	cublasSaxpy(N*(M-2), 1.0, u, 1, y, 1);

	// u = DzT
	cublasScopy(N*(M-2), f, 1, u, 1);
	Dz(f, 0, u);

	// u = v.*u, where .* denotes elementwise multiplication.
	ElemMultT<<<grid, block>>>(u,v);

	// y = y + u
	cublasSaxpy(N*(M-2), 1.0, u, 1, y, 1);

	// copy into output
	cublasScopy(N*(M-2), y, 1, output, 1);
	return;
}


//-----------------------------------------------------------------------------
//=============================================================================
//								 ENTRY POINT
//=============================================================================
//-----------------------------------------------------------------------------

int main(void) {

//=============================================================================
//								Initialization
//=============================================================================
	printf("M = %d. ",M);
	printf("N = %d. ",N);
	printf("DX = %E. ",DX);
	printf("Ra = %E.\n",RA);
	cudaDeviceProp devProp;
	cudaGetDeviceProperties(&devProp, 0);
	printf("Device 0: %s\n", devProp.name);
	cudaGetDeviceProperties(&devProp, 1);
	printf("Device 1: %s\n", devProp.name);
	cudaGetDeviceProperties(&devProp, 2);
	printf("Device 2: %s\n", devProp.name);
	cudaSetDevice(2);  // Use the Fermi on Mark2

	cublasStatus custat;  //intended to hold cublasInit messages
	printf("\nInitializing CUBLAS\n");
	cublasInit();  // Initialize cublas
	custat = cublasStatus();
	if(custat == CUBLAS_STATUS_SUCCESS) {
		printf("CUBLAS successfuly initialized\n");
	}
	else if(custat == CUBLAS_STATUS_ALLOC_FAILED) {
		printf("CUBLAS could not be initialized\n");
	}

	printf("Configuring memory.\n");
	// initialize dt to the chosen start parameter
	float dt = DT_START;
	float* d_dt; // Device-side shadow of dt, as a one-element array.
	cublasAlloc(1, sizeof(float), (void**)&d_dt);
	float* h_dt = (float*)malloc(sizeof(float)); // for ease later
	h_dt[0] = dt;
	cublasSetVector(1, sizeof(float), h_dt, 1, d_dt, 1);

	// Define T
	float* d_T;
	custat = cublasAlloc(N*(M-2), sizeof(float), (void**)&d_T);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

//	CUALLOC((M-2)*N, d_T);

	float* h_X = (float*)malloc(N*sizeof(float));
	float* h_Z = (float*)malloc((M-2)*sizeof(float));
	float* h_T = (float*)malloc(N*(M-2)*sizeof(float));

	// Set the values of X and Z
	for(int i = 0; i < N; i++) {
		h_X[i] = (i*XF + 0.0)/(N - 1.0);
	}

	// Some wonky indexing here to accomodate the fact that T has its top and
	// bottom rows chopped off.
	for(int i = 1; i < (M - 1); i++) {
		h_Z[i - 1] = (i + 0.0)/(M - 1.0);
	}
	// Initialize T, perturbing it slightly.
	for(int i = 0; i < M-2; i++) {
		for(int j = 0; j < N; j++) {
			h_T[i*N + j] = 1 - h_Z[i] + 0.01*sin(PI*h_Z[i])*cos((PI/XF)*h_X[j]);
			// For debugging purposes
			//h_T[i*N + j] = i + 1;
		}
	}

	// If INPUTT is set, overwrite h_T with the contents of input3d.bin
	// Read T from a file, if desired.
	if(INPUTT == 1) {
		uint8_t h_tbuff = 0;
		FILE *inputfile;
		inputfile = fopen("input2d.bin","r");
		for(int i = M-3; i >= 0; i--) {
			for(int j = 0; j < N; j++) {
				fread(&h_tbuff, 1, 1, inputfile);
				h_T[i*N + j] = h_tbuff;
				h_T[i*N + j] /= 255.0;
				if(h_T[i*N + j] < 0 || h_T[i*N + j] > 1) printf("Error in inputfile: value outside of range!\n");
			}
		}
		fclose(inputfile);
	}

        // If INPUTT32 is set, overwrite h_T with the contents of input3d.bin
        // Read T from a file, if desired.
        if(INPUTT32 == 1) {
                float h_tbuff = 0;
                FILE *inputfile;
                inputfile = fopen("input2d32.bin","r");
                for(int i = M-3; i >= 0; i--) {
                        for(int j = 0; j < N; j++) {
                                fread(&h_tbuff, 4, 1, inputfile);
                                h_T[i*N + j] = h_tbuff;
                        }
                }
                fclose(inputfile);
        }



	// Define the arrays necessary to calculate the Nusselt number.
	// These will be transferred to the GPU.
	float* h_ztop = (float*)malloc(4*N*sizeof(float));
	float* h_zbot = (float*)malloc(4*N*sizeof(float));


	for(int i = 0; i < 4*N; i++) {
		h_ztop[i] = 0.0;
		h_zbot[i] = 0.0;
	}

	for(int i = 0; i < N; i++ ) {
		// First row of h_ztop
		h_ztop[i] = 1-3*DX;
		// Second row of h_ztop
		h_ztop[i + N] = 1-2*DX;
		// Third row of h_ztop
		h_ztop[i + 2*N] = 1-DX;

		// Second row of h_zbot
		h_zbot[i + N] = h_Z[0];
		// Third row of h_zbot
		h_zbot[i + 2*N] = h_Z[1];
		// Fourth row of h_zbot
		h_zbot[i + 3*N] = h_Z[2];
	}

	// The bottom row of ztop is 1.0 and the top row of zbot is 0.0
	for(int i = 3*N; i < 4*N; i++) {
		h_ztop[i] = 1.0;
	}


	// Shadow T in GPU memory.  Although cublasSetMatrix assumes its input is
	// in column-major,
	cublasSetVector(N*(M-2), sizeof(float), h_T, 1, d_T, 1);
	//free(h_X);
	//free(h_Z);

	float* d_omega;
	custat = cublasAlloc((M-2)*(N-2), sizeof(float), (void**)&d_omega);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_psi;
	custat = cublasAlloc((M-2)*N, sizeof(float), (void**)&d_psi);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_dsc;
	custat = cublasAlloc((M-2)*(M-2), sizeof(float), (void**)&d_dsc);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_dsr;
	custat = cublasAlloc((N-2)*(N-2), sizeof(float), (void**)&d_dsr);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_ei;
	custat = cublasAlloc((N-2)*(M-2), sizeof(float), (void**)&d_ei);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_tr;
	custat = cublasAlloc(N*M, sizeof(float), (void**)&d_tr);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_trnu;
	custat = cublasAlloc(N, sizeof(float), (void**)&d_trnu);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Coult not allocate memory.\n");

	float* d_ztop;
	custat = cublasAlloc(4*N, sizeof(float), (void**)&d_ztop);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Coult not allocate memory.\n");

	float* d_zbot;
	custat = cublasAlloc(4*N, sizeof(float), (void**)&d_zbot);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Coult not allocate memory.\n");

	float* d_nutop;
	custat = cublasAlloc(4*N, sizeof(float), (void**)&d_nutop);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Coult not allocate memory.\n");

	float* d_nubot;
	custat = cublasAlloc(4*N, sizeof(float), (void**)&d_nubot);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Coult not allocate memory.\n");

	// alternate declarations.
//	CUALLOC((M-2)*(N-2), d_omega);
//	CUALLOC((M-2)*N, d_psi);
//	CUALLOC((M-2)*(M-2), d_dsc);
//	CUALLOC((N-2)*(N-2), d_dsr);
//	CUALLOC((M-2), d_lambda);
//	CUALLOC((N-2), d_mu);
//	CUALLOC((N-2)*(M-2), d_ei);
//	CUALLOC(N*M, d_tr);
//	CUALLOC(N, d_trnu);
//	CUALLOC(4*N, d_ztop);
//	CUALLOC(4*N, d_zbot);
//	CUALLOC(4*N, d_nutop);
//	CUALLOC(4*N, d_nubot);

	// Initialize dsr, dsc, lambda, mu, ei, and trNu and copy them over
	float* h_dsc = (float*)malloc((M-2)*(M-2)*sizeof(float));
	float* h_dsr = (float*)malloc((N-2)*(N-2)*sizeof(float));
	float* h_lambda = (float*)malloc((M-2)*sizeof(float));
	float* h_mu = (float*)malloc((N-2)*sizeof(float));
	float* h_ei = (float*)malloc((M-2)*(N-2)*sizeof(float));
	float* h_tr = (float*)malloc(M*N*sizeof(float));
	float* h_trnu = (float*)malloc(N*sizeof(float));
	// Set the value of h_dsc
	for(int i = 0; i < M-2; i++) {
		for(int j = 0; j < M-2; j++) {
			h_dsc[(M-2)*i + j] = sqrt(2.0/(M-1.0))*sin((i+1.0)*(j+1.0)*PI/(M-1.0));
			// For debugging purposes.
			//if(i == j) h_dsc[(M-2)*i + j] = 1;
			//else h_dsc[(M-2)*i + j] = 0;
		}
	}

	// Set the value of h_dsr.
	for(int i = 0; i < N-2; i++) {
		for(int j = 0; j < N-2; j++) {
			h_dsr[(N-2)*i + j] = sqrt(2.0/(N-1.0))*sin((i+1.0)*(j+1.0)*PI/(N-1.0));
			// For debugging purposes.
			//if(i == j) h_dsr[(N-2)*i + j] = 1;
			//else h_dsr[(N-2)*i + j] = 0;
		}
	}

	// Initialize lambda and mu, which are used to compute ei.
	for(int i = 0; i < M-2; i++) {
		h_lambda[i] = 2.0*cos((i + 1.0)*PI/(M - 1.0)) - 2.0;
	}

	for(int i = 0; i < N-2; i++) {
		h_mu[i] = 2.0*cos((i + 1.0)*PI/(N - 1.0)) - 2.0;
	}
	// Compute ei from lambda and mu.
	// The elements of ei are inverted on the last step to replace later
	// divisions by multiplications.
	for(int i = 0; i < M-2; i++) {
		for(int j = 0; j < N-2; j++) {
			h_ei[(N-2)*i + j] = h_lambda[i] + h_mu[j];
			h_ei[(N-2)*i + j] = (h_ei[(N-2)*i + j])*(h_ei[(N-2)*i + j]);
			h_ei[(N-2)*i + j] = 1/(h_ei[(N-2)*i + j]);
		}
	}
	// Compute tr
	for(int i = 0; i < M; i++) {
		for(int j = 0; j < N; j++) {
			h_tr[N*i + j] = DX*DX/4.0;
			if(j>0 && j<(M-1)) h_tr[N*i + j] = DX2/2.0;
			if(i>0 && i<(N-1)) h_tr[N*i + j] = DX2/2.0;
			if(j>0 && j<(M-1) && i>0 && i<(N-1)) h_tr[N*i + j] = DX2;
		}
	}

	// Compute trnu
	for(int i = 1; i < N-1; i++) {
		h_trnu[i] = DX;
	}
	h_trnu[0] = DX/2.0;
	h_trnu[N-1] = DX/2.0;

	// Copy the completed data over.
	cublasSetVector((M-2)*(M-2), sizeof(float), h_dsc, 1, d_dsc, 1);
	cublasSetVector((N-2)*(N-2), sizeof(float), h_dsr, 1, d_dsr, 1);
	cublasSetVector((M-2)*(N-2), sizeof(float), h_ei, 1, d_ei, 1);
	cublasSetVector(M*N, sizeof(float), h_tr, 1, d_tr, 1);
	cublasSetVector(N, sizeof(float), h_trnu, 1, d_trnu, 1);
	cublasSetVector(4*N, sizeof(float), h_ztop, 1, d_ztop, 1);
	cublasSetVector(4*N, sizeof(float), h_ztop, 1, d_nutop, 1);
	cublasSetVector(4*N, sizeof(float), h_zbot, 1, d_zbot, 1);
	cublasSetVector(4*N, sizeof(float), h_zbot, 1, d_nubot, 1);

	// Free the intermediate matrices (they are no longer needed host-side)
	//free(h_dsr);
	//free(h_dsc);
	//free(h_ei);
	//free(h_tr);


	float* d_u;
	custat = cublasAlloc(N*(M-2), sizeof(float), (void**)&d_u);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_v;
	custat = cublasAlloc(N*(M-2), sizeof(float), (void**)&d_v);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_xrk3;
	custat = cublasAlloc(N*(M-2), sizeof(float), (void**)&d_xrk3);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_yrk3;
	custat = cublasAlloc(N*(M-2), sizeof(float), (void**)&d_yrk3);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_zrk3;
	custat = cublasAlloc(N*(M-2), sizeof(float), (void**)&d_zrk3);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_y;
	custat = cublasAlloc(N*(M-2), sizeof(float), (void**)&d_y);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");



	float* d_Tbuff;
	custat = cublasAlloc(N*(M-2), sizeof(float), (void**)&d_Tbuff);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

	float* d_DxT;
	custat = cublasAlloc(N*(M-2), sizeof(float), (void**)&d_DxT);
	if(custat != CUBLAS_STATUS_SUCCESS) printf("Could not allocate memory.\n");

//	CUALLOC(N*(M-2), d_xrk3);
//	CUALLOC(N*(M-2), d_yrk3);
//	CUALLOC(N*(M-2), d_zrk3);
//	CUALLOC(N*(M-2), d_y);
//	CUALLOC(N*(M-2), d_u);
//	CUALLOC(N*(M-2), d_v);
//	CUALLOC(N*(M-2), d_Tbuff);
//	CUALLOC(N*(M-2), d_DxT);
//	CUALLOC(N, d_onevec);

	// use d_T to define d_psi, d_u, d_v, and d_y = 0.
	cublasScopy(N*(M-2), d_T, 1, d_psi, 1);
	cublasSaxpy(N*(M-2), -1.0, d_psi, 1, d_psi, 1);
	cublasScopy(N*(M-2), d_psi, 1, d_u, 1);
	cublasScopy(N*(M-2), d_psi, 1, d_v, 1);
	cublasScopy(N*(M-2), d_psi, 1, d_y, 1);

	//initialize all intermediate matrices to T;
	cublasScopy(N*(M-2), d_T, 1, d_xrk3, 1);
	cublasScopy(N*(M-2), d_T, 1, d_yrk3, 1);
	cublasScopy(N*(M-2), d_T, 1, d_zrk3, 1);
	cublasScopy(N*(M-2), d_T, 1, d_Tbuff, 1);
	cublasScopy(N*(M-2), d_T, 1, d_DxT, 1);


// DEBUG
// temporary buffer for use in d_*rk3 stuff
float* d_temp;
cublasAlloc(N*(M-2), sizeof(float), (void**)&d_temp);
cublasScopy(N*(M-2), d_T, 1, d_temp, 1);

	printf("Begin timestep computation: \n");

//=============================================================================
//								Computation
//=============================================================================


	// Variable to store timing information
	// clock_t is defined in time.h
	clock_t timer = clock();

	// Begin timestep computation.  Every 50 timesteps, state will be saved to
	// disk
	double frames = 0.0;
	int tstep = 0;
	for(int c = STARTSTEP; c <= ENDSTEP; c++) {
		// Use SHORTG macro to call g succinctly.
		// x = g(T,0)
		// z = g(T + (dt/3)*x, 0)
		// z = g(T + (2*dt/3)*z, 1)
		// T = T + (dt/4)*(x + 3z)
		// Store the first part of RK3 in d_xrk3
		SHORTG(d_T, 1, d_xrk3, c);

		// add (dt/3)*d_xrk3 to T, store the result in T temporarily.
//		cublasSaxpy(N*(M-2), (dt/3.0), d_xrk3, 1, d_T, 1);
//DEBUG
cublasScopy(N*(M-2), d_T, 1, d_temp,  1);
cublasSaxpy(N*(M-2), (dt/3.0), d_xrk3, 1, d_temp, 1);
		// Compute d_yrk3 = g(T + (dt/3)*d_xrk3, 0) by using the updated T.
//		SHORTG(d_T, 0, d_yrk3);

//DEBUG
SHORTG(d_temp, 0,d_yrk3,0);

		// return d_T to its original state by subtracting (dt/3)*x
//		cublasSaxpy(N*(M-2), (-(dt/3.0)), d_xrk3, 1, d_T, 1);
		// Add (2*dt/3)*d_yrk3 to T, store the result in T temporarily.
//		cublasSaxpy(N*(M-2), (2.0*(dt/3)), d_yrk3, 1, d_T, 1);
//DEBUG
cublasScopy(N*(M-2), d_T, 1, d_temp,  1);
cublasSaxpy(N*(M-2), 2.0*(dt/3.0), d_yrk3, 1, d_temp, 1);
		// Compute d_zrk3 = g(T + (2*dt/3)*d_yrk3) by using the updated T.
//		SHORTG(d_T, 1, d_zrk3);

//DEBUG
SHORTG(d_temp, 0, d_zrk3,0);

		// return d_T to its original state by subtracting (2*dt/3)*d_yrk3
//		cublasSaxpy(N*(M-2), (-(2.0*(dt/3))), d_yrk3, 1, d_T, 1);
		// T+= (dt/4)*(x + 3z)
		// Add (dt/4)*d_xrk3 to d_T
//		cublasSaxpy(N*(M-2), (dt/4.0), d_xrk3, 1, d_T, 1);
		// Add 3*(dt/4)*d_zrk3 to d_T
//		cublasSaxpy(N*(M-2), (3.0*(dt/4.0)), d_zrk3, 1, d_T, 1);
//DEBUG
cublasSaxpy(N*(M-2), (dt/4.0), d_xrk3, 1, d_T, 1);
cublasSaxpy(N*(M-2), 3.0*(dt/4.0), d_zrk3, 1, d_T, 1);


		// update the value of dt (in host) from d_dt (in device)
		cublasGetVector(1, sizeof(float), d_dt, 1, h_dt, 1);
		dt = h_dt[0];
		frames += dt;

		if(frames > FRAMESIZE) {
			tstep++;
			// CLOCKS_PER_SEC is defined as the number of clock cycles per
			// second and is variable along CPUs.
			printf("c: %d ", c);
			// Print s elapsed per timestep.
			printf("t: %Es ", (float)(clock()-timer)/(CLOCKS_PER_SEC*FRAMESIZE));
			timer = clock();
			printf("dt: %E. ", dt);

			// If PRINTNU is set, write a file that keeps track of
			// several Nu samples.
			printf("\n");
			if(PRINTNU == 1) {
				// Calculate the nusselt number throughout the array and save
				char sname[100] = "NU_" BSNAME ".bin";
				// Open a stream for writing Nu data
				FILE *nufile = fopen(sname,"a");
				float nunum = NusseltCompute(d_T, d_nutop, d_ztop, d_zbot, d_nubot, d_trnu);
				fprintf(nufile, "%.1f,", nunum);
				fclose(nufile);
			}


			// If PRINTT is set, write the temperature array to file.
			if(PRINTT == 1) {
				// Write d_T to the data file.  INVERTS ROW ORDERING
				char stringnum[25];
				char sname[100] = "T" BSNAME;
				sprintf(stringnum,"%d.bin",tstep);
				strcat(sname,stringnum);
				// Open a stream for writing T data
				FILE *tfile = fopen(sname,"w");
				cublasGetVector((M-2)*N, sizeof(float), d_T, 1, h_T, 1);
				for(int i = M-3; i > -1; i--) {
					for(int j = 0; j < N; j++) {
						WriteT32(h_T[i*N + j], tfile);
					}
				}
				fclose(tfile);
			}
			frames = 0.0;
		}
	}

	printf("Done.");
	return(0);
}
