use strict;
use warnings;  

use Test::More;
use Test::Exception;
use lib qw(t/lib);
use DBICTest;

my ($dsn, $user, $pass) = @ENV{map { "DBICTEST_SYBASE_ASA_${_}" } qw/DSN USER PASS/};

if (not $dsn) {
  plan skip_all =>
    'Set $ENV{DBICTEST_SYBASE_ASA_DSN}, _USER and _PASS to run this test' .
    "\nWarning: This test drops and creates a table called 'track'";
} else {
  eval "use DateTime; use DateTime::Format::Sybase;";
  if ($@) {
    plan skip_all => 'needs DateTime and DateTime::Format::Sybase for testing';
  }
}

my $schema;

$schema = DBICTest::Schema->clone;

$schema->connection($dsn, $user, $pass, {
  AutoCommit => 1,
  on_connect_call => [ 'datetime_setup' ],
});

# coltype, col, date
my @dt_types = (
  ['DATETIME', 'last_updated_at', '2004-08-21T14:36:48.080Z'],
# minute precision
  ['SMALLDATETIME', 'small_dt', '2004-08-21T14:36:00.000Z'],
);

for my $dt_type (@dt_types) {
  my ($type, $col, $sample_dt) = @$dt_type;

  eval { $schema->storage->dbh->do("DROP TABLE track") };
  $schema->storage->dbh->do(<<"SQL");
CREATE TABLE track (
  trackid INT IDENTITY PRIMARY KEY,
  cd INT,
  position INT,
  $col $type,
)
SQL
  ok(my $dt = DateTime::Format::Sybase->parse_datetime($sample_dt));

  my $row;
  ok( $row = $schema->resultset('Track')->create({
        $col => $dt,
        cd => 1,
      }));
  ok( $row = $schema->resultset('Track')
    ->search({ trackid => $row->trackid }, { select => [$col] })
    ->first
  );
  is( $row->$col, $dt, 'DateTime roundtrip' );
}

done_testing;

# clean up our mess
END {
  if (my $dbh = eval { $schema->storage->_dbh }) {
    $dbh->do('DROP TABLE track');
  }
}
