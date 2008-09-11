package GSLBuilder;
use Config;
use File::Copy;
use File::Spec::Functions qw/:ALL/;
use base 'Module::Build';

sub process_swig_files {
    my $self = shift;
    my $p = $self->{properties};
    return unless $p->{swig_source};
    my $files_ref = $p->{swig_source};
    foreach my $file (@$files_ref) {
        $self->process_swig($file->[0], $file->[1]);
    }
}

# Check check dependencies for $main_swig_file. These are the
# %includes. If needed, arrange to run swig on $main_swig_file to
# produce a xxx_wrap.c C file.

sub process_swig {
    my ($self, $main_swig_file, $deps_ref) = @_;
    my ($cf, $p) = ($self->{config}, $self->{properties}); # For convenience

    # File name. e.g, perlcdio.swg -> perlcdio_wrap.c
    (my $file_base = $main_swig_file) =~ s/\.[^.]+$//;
    my $c_file = "${file_base}_wrap.c";

    $self->compile_swig($main_swig_file, $c_file) 
    unless($self->up_to_date( [$main_swig_file, @$deps_ref ],$c_file)); 

    # .c -> .o
    my $obj_file = $self->compile_c($c_file);
    $self->add_to_cleanup($obj_file);

    # The .so files don't go in blib/lib/, they go in blib/arch/auto/.
    # Unfortunately we have to pre-compute the whole path.
    my $archdir;
    {
        my @dirs = splitdir($file_base);
        $archdir = catdir($self->blib,'arch', @dirs[1..$#dirs]);
    }

    # .o -> .so
    $self->link_c($archdir, $file_base, $obj_file);
}

# Invoke swig with -perl -outdir and other options.
sub compile_swig {
    my ($self, $file, $c_file) = @_;
    my ($cf, $p) = ($self->{config}, $self->{properties}); # For convenience
    my  @swig_flags = ();

    # File name, minus the suffix
    (my $file_base = $file) =~ s/\.[^.]+$//;
    
    my @swig = qw/ swig /;
    if (defined($p->{swig})) {
	    @swig = $self->split_like_shell($p->{swig});
    }
    if (defined($p->{swig_flags})) {
	    @swig_flags = $self->split_like_shell($p->{swig_flags});
    }
   
    my $blib_lib =  catfile(qw/blib lib/);

    mkdir catfile($blib_lib, qw/Math GSL/);
    my $outdir  = catfile($blib_lib, qw/Math GSL/);
    my $pm_file = "${file_base}.pm";
    my $from    = catfile($blib_lib, qw/Math GSL/, $pm_file);
    my $to      = catfile(qw/lib Math GSL/,$pm_file);
    chmod 0644, $from, $to;

    $self->do_system(@swig, '-o', $c_file,
                     '-outdir', $outdir, 
		             '-perl5', @swig_flags, $file)
	    or die "error building $c_file file from '$file'";
    

    print "Copying from: $from, to: $to; it makes the CPAN indexer happy.\n";
    copy($from,$to);
    return $c_file;
}
sub is_windows { $^O =~ /MSWin32/i }

# Windows fixes courtesy of <sisyphus@cpan.org>
sub link_c {
  my ($self, $to, $file_base, $obj_file) = @_;
  my ($cf, $p) = ($self->{config}, $self->{properties}); # For convenience

  my $lib_file = catfile($to, File::Basename::basename("$file_base.$Config{dlext}"));

  $self->add_to_cleanup($lib_file);
  my $objects = $p->{objects} || [];
  
  unless ($self->up_to_date([$obj_file, @$objects], $lib_file)) {
    my @linker_flags = $self->split_like_shell($p->{extra_linker_flags});

    push @linker_flags, $Config{archlib} . '/CORE/' . $Config{libperl} if is_windows();

    my @lddlflags = $self->split_like_shell($cf->{lddlflags}); 
    my @shrp = $self->split_like_shell($cf->{shrpenv});
    my @ld = $self->split_like_shell($cf->{ld}) || "gcc";

    # Strip binaries if we are compiling on windows
    push @ld, "-s" if (is_windows() && $Config{cc} eq 'gcc');

    $self->do_system(@shrp, @ld, @lddlflags, @user_libs, '-o', $lib_file,
		     $obj_file, @$objects, @linker_flags)
      or die "error building $lib_file file from '$obj_file'";
  }
  
  return $lib_file;
}

# From Base.pm but modified to put package cflags *after* 
# installed c flags so warning-removal will have an effect.

sub compile_c {
  my ($self, $file) = @_;
  my ($cf, $p) = ($self->{config}, $self->{properties}); # For convenience
  
  # File name, minus the suffix
  (my $file_base = $file) =~ s/\.[^.]+$//;
  my $obj_file = $file_base . $Config{_o};

  $self->add_to_cleanup($obj_file);
  return $obj_file if $self->up_to_date($file, $obj_file);


  $cf->{installarchlib} = $Config{archlib};

  my @include_dirs = @{$p->{include_dirs}} 
			? map {"-I$_"} (@{$p->{include_dirs}}, catdir($cf->{installarchlib}, 'CORE'))
			: map {"-I$_"} ( catdir($cf->{installarchlib}, 'CORE') ) ;

  my @extra_compiler_flags = $self->split_like_shell($p->{extra_compiler_flags});

  my @cccdlflags = $self->split_like_shell($cf->{cccdlflags});

  my @ccflags  = $self->split_like_shell($cf->{ccflags});
  push @ccflags, $self->split_like_shell($Config{cppflags});

  my @optimize = $self->split_like_shell($cf->{optimize});

  # Whoah! There seems to be a bug in gcc 4.1.0 and optimization
  # and swig. I'm not sure who's at fault. But for now the simplest
  # thing is to turn off all optimization. For the kinds of things that
  # SWIG does - do conversions between parameters and transfers calls
  # I doubt optimization makes much of a difference. But if it does,
  # it can be added back via @extra_compiler_flags.

  my @flags = (@include_dirs, @cccdlflags, '-c', @ccflags, @extra_compiler_flags, );
  
  my @cc = $self->split_like_shell($cf->{cc});
  @cc = "gcc" unless @cc;
  
  $self->do_system(@cc, @flags, '-o', $obj_file, $file)
    or die "error building $Config{_o} file from '$file'";

  return $obj_file;
}

3.14;
