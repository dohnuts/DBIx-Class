package DBIx::Class::Storage::DBI::Pg::Sth;
use strict;
use warnings;
use base 'Class::Accessor::Grouped';

__PACKAGE__->mk_group_accessors('simple' =>
                                    'storage',
                                    'cursor_id', 'cursor_sql',
                                    'cursor_created',
                                    'cursor_sth', 'fetch_sth',
                                    'page_size',
                            );

sub new {
    my ($class, $storage, $dbh, $sql, $page_size) = @_;

    if ($sql =~ /^SELECT\b/i) {
        my $self=bless {},$class;
        $self->storage($storage);

        my $csr_id=$self->_cursor_name_from_number(
            $storage->_get_next_pg_cursor_number()
        );
        my $hold= ($sql =~ /\bFOR\s+UPDATE\s*\z/i) ? '' : 'WITH HOLD';
        $self->cursor_sql("DECLARE $csr_id CURSOR $hold FOR $sql");
        $self->cursor_id($csr_id);
        $self->cursor_sth(undef);
        $self->cursor_created(0);
        $self->page_size($page_size);
        return $self;
    }
    else {
        die "Can only be used for SELECTs";
    }
}

sub _cursor_name_from_number {
    return 'dbic_pg_cursor_'.$_[1];
}

sub _prepare_cursor_sth {
    my ($self)=@_;

    return if $self->cursor_sth;

    $self->cursor_sth($self->storage->sth($self->cursor_sql));
}

sub _cleanup_sth {
    my ($self)=@_;

    if ($self->fetch_sth) {
        $self->fetch_sth->finish();
        $self->fetch_sth(undef);
    }
    if ($self->cursor_sth) {
        $self->cursor_sth->finish();
        $self->cursor_sth(undef);
        $self->storage->dbh->do('CLOSE '.$self->cursor_id);
    }
}

sub DESTROY {
    my ($self) = @_;

    eval { $self->_cleanup_sth };

    return;
}

sub bind_param {
    my ($self,@bind_args)=@_;

    $self->_prepare_cursor_sth;

    return $self->cursor_sth->bind_param(@bind_args);
}

sub execute {
    my ($self,@bind_values)=@_;

    $self->_prepare_cursor_sth;

    my $ret=$self->cursor_sth->execute(@bind_values);
    $self->cursor_created(1) if $ret;
    return $ret;
}

# bind_param_array & execute_array not used for SELECT statements, so
# we'll ignore them

sub errstr {
    my ($self)=@_;

    return $self->cursor_sth->errstr;
}

sub finish {
    my ($self)=@_;

    $self->fetch_sth->finish if $self->fetch_sth;
    return $self->cursor_sth->finish if $self->cursor_sth;
    return 1;
}

sub _check_cursor_end {
    my ($self) = @_;

    if ($self->fetch_sth->rows == 0) {
        $self->_cleanup_sth;
        return 1;
    }
    return;
}

sub _run_fetch_sth {
    my ($self)=@_;

    if (!$self->cursor_created) {
        $self->execute();
    }

    $self->fetch_sth->finish if $self->fetch_sth;
    $self->fetch_sth($self->storage->sth(
        sprintf 'fetch %d from %s',
        $self->page_size,
        $self->cursor_id
    ));
    $self->fetch_sth->execute;
}

sub fetchrow_array {
    my ($self) = @_;

    $self->_run_fetch_sth unless $self->fetch_sth;
    return if $self->_check_cursor_end;

    my @row = $self->fetch_sth->fetchrow_array;
    if (!@row) {
        $self->_run_fetch_sth;
        return if $self->_check_cursor_end;

        @row = $self->fetch_sth->fetchrow_array;
    }
    return @row;
}

sub fetchall_arrayref {
    my ($self,$slice,$max_rows) = @_;

    my $ret=[];
    $self->_run_fetch_sth unless $self->fetch_sth;
    return if $self->_check_cursor_end;

    while (1) {
        my $batch=$self->fetch_sth->fetchall_arrayref($slice,$max_rows);

        push @$ret,@$batch;

        if (defined($max_rows) && $max_rows >=0) {
            $max_rows -= @$batch;
            last if $max_rows <=0;
        }

        last if @$batch ==0;

        $self->_run_fetch_sth;
        last if $self->_check_cursor_end;
    }

    return $ret;
}

1;