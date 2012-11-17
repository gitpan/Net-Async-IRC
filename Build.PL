use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
   module_name => 'Net::Async::IRC',
   requires => {
      'IO::Async::Protocol::LineStream' => '0.34',
      'Time::HiRes' => 0,
   },
   build_requires => {
      'IO::Async' => '0.30',
      'IO::Async::Test' => 0.14,
      'Test::Fatal' => 0,
      'Test::More' => 0,
   },
   auto_configure_requires => 0, # Don't add M::B to configure_requires
   license => 'perl',
   create_makefile_pl => 'traditional',
   create_license => 1,
   create_readme  => 1,
);

$build->create_build_script;
