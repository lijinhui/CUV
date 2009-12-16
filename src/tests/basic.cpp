#define BOOST_TEST_MODULE example
#include <boost/test/included/unit_test.hpp>

#include <cuv_general.hpp>
#include <dev_dense_matrix.hpp>
#include <host_dense_matrix.hpp>

using namespace cuv;

struct Fix{
	Fix(){
	}
	~Fix(){
	}
};


BOOST_FIXTURE_TEST_SUITE( s, Fix )


BOOST_AUTO_TEST_CASE( create_dev_plain )
{
	dev_dense_matrix<float> m(16,16);
}

BOOST_AUTO_TEST_CASE( create_dev_view )
{
	dev_dense_matrix<float> m(16,16);
	dev_dense_matrix<float> m2(16,16,new dev_vector<float>(m.n(), m.ptr(), true));
}

BOOST_AUTO_TEST_CASE( create_dev_from_mat )
{
	dev_dense_matrix<float> m(16,16);
	dev_dense_matrix<float> m2(&m);
}

BOOST_AUTO_TEST_CASE( create_host )
{
	host_dense_matrix<float> m(16,16);
	host_dense_matrix<float> m2(16,16,new host_vector<float>(m.n(),m.ptr(),true));
}


BOOST_AUTO_TEST_SUITE_END()