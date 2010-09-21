use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
   module_name => 'Net::Async::IRC',
   requires => {
      'IO::Async::Protocol::Stream' => 0,
      'Time::HiRes' => 0,
   },
   build_requires => {
      'IO::Async' => 0.21,
      'IO::Async::Test' => 0.14,
      'Test::More' => 0,
      'Test::Exception' => 0,
   },
   license => 'perl',
   create_makefile_pl => 'traditional',
   create_license => 1,
   create_readme  => 1,
);
  
$build->create_build_script;
