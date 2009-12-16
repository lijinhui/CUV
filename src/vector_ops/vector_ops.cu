#include <iostream>

#include <thrust/device_ptr.h>
#include <thrust/device_malloc.h>
#include <thrust/device_free.h>
#include <thrust/device_vector.h>
#include <thrust/sequence.h>
#include <thrust/transform_reduce.h>
#include <thrust/generate.h>

#include <cuv_general.hpp>

#include <dev_vector.hpp>
#include <host_vector.hpp>

#include "vector_ops.hpp"

#define sgn(a) (copysign(1.f,a))

/*
 * USE_THRUST_LAUNCHER:
 * thrust has an overhead for looking up the correct block/grid-size for threads.
 * this overhead goes away for matrices of about 784*2048 for very simple linear kernels,
 * then they are better on bigcuda1.
 *
 */
#define USE_THRUST_LAUNCHER 1 


using namespace cuv;
using namespace std;

template<class T, class M>
struct memspace_cuv2thrustptr                          { typedef T* ptr_type; };
template<class T>
struct memspace_cuv2thrustptr<T,cuv::host_memory_space>{ typedef T* ptr_type; };
template<class T>
struct memspace_cuv2thrustptr<T,cuv::dev_memory_space> { typedef thrust::device_ptr<T> ptr_type; };

template<class T>
/*struct uf_exp{  __host__ __device__         T operator()(const T& t)const{ return __expf(t);    } };*/
struct uf_exp{  __host__ __device__         T operator()(const T& t)const{ return exp(t);    } };
template<class T>
struct uf_exact_exp{  __device__ __host__   T operator()(const T& t)const{ return exp(t);    } };
template<class T>
struct uf_log{  __device__ __host__         T operator()(const T& t)      const{ return log(t);    } };
template<class T>
struct uf_sign{  __device__ __host__        T operator()(const T& t)      const{ return sgn((float)t);    } };
template<class T>
/*struct uf_sigm{  __device__  __host__       T operator()(const T& t)      const{ return ((T)1)/(((T)1)+__expf(-t));    } };*/
struct uf_sigm{  __device__  __host__       T operator()(const T& t)      const{ return ((T)1)/(((T)1)+exp(-t));    } };
template<class T>
struct uf_exact_sigm{  __device__  __host__ T operator()(const T& t)      const{ return ((T)1)/(((T)1)+exp(-t));    } };
template<class T>
struct uf_dsigm{  __device__ __host__       T operator()(const T& t)      const{ return t * (((T)1)-t); } };
template<class T>
struct uf_tanh{  __device__  __host__       T operator()(const T& t)      const{ return tanh(t); } };
template<class T>
struct uf_dtanh{  __device__  __host__      T operator()(const T& t)      const{ return ((T)1) - (t*t); } };
template<class T>
struct uf_square{  __device__  __host__     T operator()(const T& t)      const{ return t*t; } };
template<class T>
struct uf_sublin{  __device__  __host__     T operator()(const T& t)      const{ return ((T)1)-t; } };
template<class T>
struct uf_energ{  __device__  __host__      T operator()(const T& t)      const{ return -log(t); } };
template<class T>
struct uf_inv{  __device__  __host__        T operator()(const T& t)      const{ return ((T)1)/(t+((T)0.00000001)); } };
template<class T>
struct uf_sqrt{  __device__  __host__       T operator()(const T& t)      const{ return sqrt(t); } };
template<class T>
struct uf_abs{  __device__  __host__       T operator()(const T& t)      const{ return fabs(t); } };

template<class T, class binary_functor>
struct uf_base_op{
  const T x;
  const binary_functor bf;
  uf_base_op(const T& _x):x(_x),bf(){};
  T operator()(T t){ return bf(t,x); }
};

/*
 * Binary Functors
 */

template<class T, class U>
struct bf_plus{  __device__  __host__       T operator()(const T& t, const U& u)      const{ return  t + (T)u; } };
template<class T, class U>
struct bf_minus{  __device__  __host__       T operator()(const T& t, const U& u)      const{ return  t - (T)u; } };
template<class T, class U>
struct bf_multiplies{  __device__  __host__       T operator()(const T& t, const U& u)      const{ return  t * (T)u; } };
template<class T, class U>
struct bf_divides{  __device__  __host__       T operator()(const T& t, const U& u)      const{ return  t / (T)u; } };
template<class T, class U>
struct bf_squared_diff{  __device__  __host__       T operator()(const T& t, const U& u)      const{ T ret =  t - (T)u; return ret*ret; } };

template<class T, class U>
struct bf_axpy{  
	const T a;
	bf_axpy(const T& _a):a(_a){}
	__device__  __host__       T operator()(const T& t, const U& u) const{ return  a*t+(T)u; } 
};
template<class T, class U>
struct bf_xpby{  
	const T b;
	bf_xpby(const T& _b):b(_b){}
	__device__  __host__       T operator()(const T& t, const U& u) const{ return  t+b*(T)u; } 
};
template<class T, class U>
struct bf_axpby{  
	const T a;
	const T b;
	bf_axpby(const T& _a, const T& _b):a(_a),b(_b){}
	__device__  __host__       T operator()(const T& t, const U& u) const{ return  a*t + b*((T)u); } 
};

#if ! USE_THRUST_LAUNCHER
template<class unary_functor, class value_type, class index_type>
__global__
void unary_functor_kernel(value_type* dst, value_type* src, index_type n, unary_functor uf){
	const unsigned int idx = __mul24(blockIdx.x , blockDim.x) + threadIdx.x;
	const unsigned int off = __mul24(blockDim.x , gridDim.x);
	for (unsigned int i = idx; i < n; i += off)
		dst[i] = uf(src[i]);
}

void setLinearGridAndThreads(dim3& blocks, dim3& threads, size_t len, int threads_per_block=512){
	const int padded_len=(int)ceil((float)len/threads_per_block)*threads_per_block;
	blocks = dim3(min(512,padded_len/threads_per_block),1,1);
	threads = dim3(threads_per_block,1,1);
}
#endif

template<class unary_functor, class value_type, class index_type>
void launch_unary_kernel(
   cuv::dev_vector<value_type, index_type>& dst,
   cuv::dev_vector<value_type, index_type>& src, 
	 unary_functor uf){
	 cuvAssert(dst.ptr());
	 cuvAssert(src.ptr());
	 cuvAssert(dst.size() == src.size());


#if ! USE_THRUST_LAUNCHER
	 dim3 blocks, threads;
	 setLinearGridAndThreads(blocks,threads,dst.size());
	 unary_functor_kernel<<<blocks,threads>>>(dst.ptr(),src.ptr(),dst.size(),uf);
#else
	 thrust::device_ptr<value_type> dst_ptr(dst.ptr());
	 thrust::device_ptr<value_type> src_ptr(src.ptr());
	 thrust::transform(src_ptr,src_ptr+src.size(),dst_ptr,uf);
#endif

	 cuvSafeCall(cudaThreadSynchronize());
}

template<class unary_functor, class value_type, class index_type>
void launch_unary_kernel(
   cuv::host_vector<value_type, index_type>& dst,
   cuv::host_vector<value_type, index_type>& src, 
	 unary_functor uf){
	 cuvAssert(src.ptr());
	 cuvAssert(dst.ptr());
	 cuvAssert(dst.size() == src.size());
	 for(size_t i=0;i<dst.size();i++)
	   dst[i] = uf(src[i]);
}

namespace cuv{
	
/*
 * Nullary Functor
 *
 */

template<class __vector_type>
void
apply_0ary_functor(__vector_type& v, const NullaryFunctor& nf){
	 cuvAssert(v.ptr());
	 typedef typename __vector_type::value_type value_type;
	 typedef typename memspace_cuv2thrustptr<value_type,typename __vector_type::memspace_type>::ptr_type ptr_type;
	 ptr_type dst_ptr(v.ptr());
	 switch(nf){
		 case NF_SEQ:
			 thrust::sequence(dst_ptr,dst_ptr+v.size());break;
		 default:
			 cuvAssert(false);
	 }
	 cuvSafeCall(cudaThreadSynchronize());
}

template<class __vector_type, class __value_type>
void
apply_0ary_functor(__vector_type& v, const NullaryFunctor& nf, const __value_type& param){
	 cuvAssert(v.ptr());

	 typedef typename __vector_type::value_type value_type;
	 typedef typename memspace_cuv2thrustptr<value_type,typename __vector_type::memspace_type>::ptr_type ptr_type;
	 ptr_type dst_ptr(v.ptr());
	 switch(nf){
		 case NF_FILL:
			 thrust::fill(dst_ptr,dst_ptr + v.size(), (value_type)param); break;
		 default:
			 cuvAssert(false);
	 }
	 cuvSafeCall(cudaThreadSynchronize());
}

/*
 * Unary Functor
 *
 */
template<class __vector_type>
struct apply_scalar_functor_impl;

template<class __vector_type>
void
apply_scalar_functor(__vector_type& v, const ScalarFunctor& sf){
  apply_scalar_functor_impl<__vector_type>::apply(v,sf);
}
template<class __vector_type, class __value_type>
void
apply_scalar_functor(__vector_type& v, const ScalarFunctor& sf, const __value_type& param){
  apply_scalar_functor_impl<__vector_type>::apply(v,sf,param);
}

/*
 * Binary Functor
 *
 */
template<class __vector_type1, class __vector_type2>
void
apply_binary_functor(__vector_type1& v, __vector_type2& w, const BinaryFunctor& sf){
	cuvAssert(v.size() == w.size());
	typedef typename __vector_type1::value_type V1;
	typedef typename __vector_type2::value_type V2;
	typedef typename memspace_cuv2thrustptr<V1,typename __vector_type1::memspace_type>::ptr_type ptr_type1;
	typedef typename memspace_cuv2thrustptr<V2,typename __vector_type2::memspace_type>::ptr_type ptr_type2;
	ptr_type1 v_ptr(v.ptr());
	ptr_type2 w_ptr(w.ptr());
	switch(sf){
		case BF_ADD:      thrust::transform(v_ptr, v_ptr+v.size(), w_ptr,  v_ptr, bf_plus<V1,V2>()); break;
		case BF_SUBTRACT: thrust::transform(v_ptr, v_ptr+v.size(), w_ptr,  v_ptr, bf_minus<V1,V2>()); break;
		case BF_MULT:     thrust::transform(v_ptr, v_ptr+v.size(), w_ptr,  v_ptr, bf_multiplies<V1,V2>()); break;
		case BF_DIV:      thrust::transform(v_ptr, v_ptr+v.size(), w_ptr,  v_ptr, bf_divides<V1,V2>()); break;
		case BF_COPY:     thrust::copy(w_ptr, w_ptr+v.size(), v_ptr); break;
		default: cuvAssert(false);
	}
}

template<class __vector_type1, class __vector_type2, class __value_type>
void
apply_binary_functor(__vector_type1& v, __vector_type2& w, const BinaryFunctor& sf, const __value_type& param){
	cuvAssert(v.size() == w.size());
	typedef typename __vector_type1::value_type V1;
	typedef typename __vector_type2::value_type V2;
	typedef typename memspace_cuv2thrustptr<V1,typename __vector_type1::memspace_type>::ptr_type ptr_type1;
	typedef typename memspace_cuv2thrustptr<V2,typename __vector_type2::memspace_type>::ptr_type ptr_type2;
	ptr_type1 v_ptr(v.ptr());
	ptr_type2 w_ptr(w.ptr());
	switch(sf){
		case BF_AXPY:     thrust::transform(v_ptr, v_ptr+v.size(), w_ptr,  v_ptr, bf_axpy<V1,V2>(param)); break;
		case BF_XPBY:     thrust::transform(v_ptr, v_ptr+v.size(), w_ptr,  v_ptr, bf_xpby<V1,V2>(param)); break;
		default: cuvAssert(false);
	}
}

template<class __vector_type1, class __vector_type2, class __value_type>
void
apply_binary_functor(__vector_type1& v, __vector_type2& w, const BinaryFunctor& sf, const __value_type& param, const __value_type& param2){
	cuvAssert(v.size() == w.size());
	typedef typename __vector_type1::value_type V1;
	typedef typename __vector_type2::value_type V2;
	typedef typename memspace_cuv2thrustptr<V1,typename __vector_type1::memspace_type>::ptr_type ptr_type1;
	typedef typename memspace_cuv2thrustptr<V2,typename __vector_type2::memspace_type>::ptr_type ptr_type2;
	ptr_type1 v_ptr(v.ptr());
	ptr_type2 w_ptr(w.ptr());
	switch(sf){
		case BF_AXPBY:     thrust::transform(v_ptr, v_ptr+v.size(), w_ptr,  v_ptr, bf_axpby<V1,V2>(param,param2)); break;
		default: cuvAssert(false);
	}
	cuvSafeCall(cudaThreadSynchronize());
}

template<class __vector_type>
struct apply_scalar_functor_impl{

	template<class __arg_value_type>
	static void
	apply(__vector_type& v, const ScalarFunctor& sf, const __arg_value_type& param){
		typedef typename __vector_type::value_type value_type;
		switch(sf){
			case SF_ADD:       launch_unary_kernel(v,v,uf_base_op<value_type, thrust::plus<value_type> >(param)); break;
			case SF_MULT:      launch_unary_kernel(v,v,uf_base_op<value_type, thrust::multiplies<value_type> >(param)); break;
			case SF_DIV:       launch_unary_kernel(v,v,uf_base_op<value_type, thrust::divides<value_type> >(param)); break;
			case SF_SUBTRACT:  launch_unary_kernel(v,v,uf_base_op<value_type, thrust::minus<value_type> >(param)); break;
		}
	}

	static void
	apply(__vector_type& v, const ScalarFunctor& sf){
		typedef typename __vector_type::value_type value_type;
	  switch(sf){
			case SF_EXP:        launch_unary_kernel(v,v, uf_exp<value_type>()); break;
			case SF_EXACT_EXP:  launch_unary_kernel(v,v, uf_exact_exp<value_type>()); break;
			case SF_LOG:        launch_unary_kernel(v,v, uf_log<value_type>()); break;
			case SF_SIGN:       launch_unary_kernel(v,v, uf_sign<value_type>()); break;
			case SF_SIGM:       launch_unary_kernel(v,v, uf_sigm<value_type>()); break;
			case SF_DSIGM:      launch_unary_kernel(v,v, uf_dsigm<value_type>()); break;
			case SF_TANH:       launch_unary_kernel(v,v, uf_tanh<value_type>()); break;
			case SF_DTANH:      launch_unary_kernel(v,v, uf_dtanh<value_type>()); break;
			case SF_SQUARE:     launch_unary_kernel(v,v, uf_square<value_type>()); break;
			case SF_SUBLIN:     launch_unary_kernel(v,v, uf_sublin<value_type>()); break;
			case SF_ENERG:      launch_unary_kernel(v,v, uf_energ<value_type>()); break;
			case SF_INV:        launch_unary_kernel(v,v, uf_inv<value_type>()); break;
			case SF_SQRT:       launch_unary_kernel(v,v, uf_sqrt<value_type>()); break;
			case SF_NEGATE:     launch_unary_kernel(v,v, thrust::negate<value_type>()); break;
			default:
			 cuvAssert(false);
		}
	}
};

template<class __vector_type>
float
norm2(__vector_type& v){
	typedef typename __vector_type::value_type value_type;
	typedef typename memspace_cuv2thrustptr<value_type,typename __vector_type::memspace_type>::ptr_type ptr_type;
	ptr_type v_ptr(v.ptr());
	float init=0;
	return  std::sqrt( thrust::transform_reduce(v_ptr, v_ptr+v.size(), uf_square<float>(), init, bf_plus<float,value_type>()) );
}
template<class __vector_type>
float
norm1(__vector_type& v){
	typedef typename __vector_type::value_type value_type;
	typedef typename memspace_cuv2thrustptr<value_type,typename __vector_type::memspace_type>::ptr_type ptr_type;
	ptr_type v_ptr(v.ptr());
	float init=0;
	return   thrust::transform_reduce(v_ptr, v_ptr+v.size(), uf_abs<float>(), init, bf_plus<float,value_type>());
}
template<class __vector_type>
float
mean(__vector_type& v){
	typedef typename __vector_type::value_type value_type;
	typedef typename memspace_cuv2thrustptr<value_type,typename __vector_type::memspace_type>::ptr_type ptr_type;
	ptr_type v_ptr(v.ptr());
	float init=0;
	return   thrust::reduce(v_ptr, v_ptr+v.size(), init, bf_plus<float,value_type>()) / (float)v.size();
}
template<class __vector_type>
float
var(__vector_type& v){
	typedef typename __vector_type::value_type value_type;
	typedef typename memspace_cuv2thrustptr<value_type,typename __vector_type::memspace_type>::ptr_type ptr_type;
	ptr_type v_ptr(v.ptr());
	float init=0;
	float m = mean(v);
	return   thrust::transform_reduce(v_ptr, v_ptr+v.size(), uf_base_op<float, bf_squared_diff<float,value_type> >(m), init, bf_plus<float,value_type>()) / (float)v.size();
}


#define SIMPLE_0(X) \
	template void apply_0ary_functor< X >(X&, const NullaryFunctor&);

#define SIMPLE_01(X,P) \
	template void apply_0ary_functor< X, P>(X&, const NullaryFunctor&, const P& param);

#define SIMPLE_1(X) \
	template void apply_scalar_functor< X >(X&, const ScalarFunctor&);
#define SIMPLE_11(X,P) \
	template void apply_scalar_functor< X, P>(X&, const ScalarFunctor&,const P&);

#define SIMPLE_2(X,Y) \
	template void apply_binary_functor<X,Y  >(X&, Y&, const BinaryFunctor&);
#define SIMPLE_21(X,Y,P) \
	template void apply_binary_functor<X,Y,P>(X&, Y&, const BinaryFunctor&,  const P&); \
	template void apply_binary_functor<X,Y,P>(X&, Y&, const BinaryFunctor&,  const P&, const P&);

#define SIMPLE_NORM(X) \
	template float norm1<X>(X&); \
	template float norm2<X>(X&); \
	template float mean<X>(X&);  \
	template float var<X>(X&); 


#define SIMPLE_INSTANTIATOR(X) \
	SIMPLE_0( X );             \
	SIMPLE_1( X );             \
	SIMPLE_2( X, X );          \
    SIMPLE_NORM( X );

#define SIMPLE_INSTANTIATOR1(X, P) \
	SIMPLE_01( X, P );             \
	SIMPLE_11( X, P );             \
	SIMPLE_21( X, X, P );          

SIMPLE_INSTANTIATOR( dev_vector<float> );
SIMPLE_INSTANTIATOR1( dev_vector<float>, float );
SIMPLE_INSTANTIATOR1( dev_vector<float>, int );
SIMPLE_INSTANTIATOR( dev_vector<unsigned char> );
SIMPLE_INSTANTIATOR1( dev_vector<unsigned char>, unsigned char );

SIMPLE_INSTANTIATOR( host_vector<float> );
SIMPLE_INSTANTIATOR1( host_vector<float>, float );
SIMPLE_INSTANTIATOR1( host_vector<float>, int );
SIMPLE_INSTANTIATOR( host_vector<unsigned char> );
SIMPLE_INSTANTIATOR1( host_vector<unsigned char>, unsigned char );

} // cuv