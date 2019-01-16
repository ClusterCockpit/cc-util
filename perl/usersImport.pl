#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use LWP::Simple;
use DBI;
use Log::Log4perl;
use Data::Dumper;
use File::Copy;

my $cwd = '/home/unrz254/MONITOR';

##### Configuration #######
my %config = do "$cwd/config.pl";
##########################

# Set to 1 for dry run without altering database
my $DRY = 0;

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
# WTF !!
$year += 1900;
$mon++;
my $date = sprintf "%02d%02d%0d",$mday,$mon,$year%100;
my $passwd_file = "passwd-emmy-$date.txt";
my $group_file =  "group-emmy-$date.txt";

Log::Log4perl->init("$cwd/log.conf");
my $log = Log::Log4perl->get_logger("usersImport");

my $dbh = DBI->connect(
    'DBI:mysql:'.$config{DB_name},
    $config{DB_user},
    $config{DB_passwd})
    or die "Could not connect to database: $DBI::errstr";

open(FILE,'<',"$cwd/$group_file");
my @groups;
my %userGroup;
my %activeUsers;

while ( my $line =  <FILE> ) {
    my @entries = split(/:/, $line);

    my $group_id = $entries[0];
    my $gid = $entries[2];
    my @members = split(/,/,$entries[3]);

    push @groups, {
        group_id => $group_id,
        gid      => $gid,
        members  => \@members
    };

    foreach my $user ( @members ) {
        push(@{$userGroup{$user}}, $group_id);

        if ( $group_id eq 'infohpc' ) {
            $activeUsers{$user} = 1;
        }
    }
}

close FILE;

my @users;
open(FILE,'<',"$cwd/$passwd_file");

while ( my $line =  <FILE> ) {
    my @entries = split(/:/, $line);
    my $user_id = $entries[0];
    my $uid     = $entries[2];
    my $name    = $entries[4];
    my $email   = $entries[0].'@mailhub.uni-erlangen.de';

    push @users, {
        user_id => $user_id,
        uid     => $uid,
        name    => $name,
        email   => $email,
        active  => $activeUsers{$user_id} ? 1 : 0,
        groups  => \$userGroup{$user_id}
    };
}

close FILE;

# Extract DB current state
my $sth = $dbh->prepare("SELECT * FROM user");
$sth->execute();
my $usersDB = $sth->fetchall_hashref('user_id');

$sth = $dbh->prepare("SELECT * FROM unix_group");
$sth->execute();
my $groupsDB = $sth->fetchall_hashref('group_id');

# print Dumper(@users);
# print Dumper(usersDB);

# update groups
$sth = $dbh->prepare(q{
    INSERT INTO unix_group (group_id, gid) VALUES (?,?)
}) or die $dbh->errstr;

foreach my $group ( @groups ){
    my $groupId = $group->{group_id};

    if ( not exists $groupsDB->{$groupId} ) {
        $log->debug("Add group $groupId");
        $sth->execute($group->{group_id}, $group->{gid}) unless $DRY;
    }
}

# update users
$sth = $dbh->prepare_cached(q{
    INSERT INTO user (user_id, uid, name, email) VALUES (?,?,?,?)
}) or die $dbh->errstr;

foreach my $user ( @users ){
    my $userId = $user->{user_id};

    if ( exists $usersDB->{$userId} ){
        my $name = $user->{name};

        if( $name ne $usersDB->{$userId}->{name} ){
            $log->debug("$userId: New name $name");
            unless ( $DRY ) {
                $dbh->do(q{
                    UPDATE user SET name = ? WHERE user_id = ?
                    }, undef, ($name, $userId)) or die $dbh->errstr;
            }
        }
        #TODO Implement changed group membership
    } else {
        # add new user
        $log->debug("Add user $userId");
        $sth->execute($userId, $user->{uid} ,$user->{name}, $user->{email}) unless $DRY;
    }
}

# update active users
# set all users to inactive
unless ( $DRY ) {
    $dbh->do('UPDATE user SET active=false') or die $dbh->errstr;
}

unless ( $DRY ) {
    $sth = $dbh->prepare(q{
        UPDATE user SET active=true WHERE user_id=?
        }) or die $dbh->errstr;
}

while (my ($userId, $value) = each %activeUsers) {
    $sth->execute($userId) unless $DRY;
}

my $countFile = @users;
my $countDB = keys %$usersDB;
my $countActive = keys %activeUsers;
$log->info("Import users on $date - File $countFile - DB $countDB - Active $countActive ");

move("$cwd/$passwd_file", "$cwd/users/$passwd_file") unless $DRY;
move("$cwd/$group_file", "$cwd/users/$group_file") unless $DRY;

$dbh->disconnect();
