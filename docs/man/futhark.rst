.. role:: ref(emphasis)

.. _futhark(1):

=======
futhark
=======

SYNOPSIS
========

futhark <subcommand> options...

DESCRIPTION
===========

Futhark is a data-parallel functional array language.  Through various
subcommands, the ``futhark`` tool provides facilities for compiling,
developing, or analysing Futhark programs.  Most subcommands are
documented in their own manpage.  For example, ``futhark opencl`` is
documented as :ref:`futhark-opencl(1)`.  The remaining subcommands are
documented in this page.

COMMANDS
========

futhark check PROGRAM
---------------------

Check whether a Futhark program type checks.

futhark datacmp FILE_A FILE_B
-----------------------------

Check whether the two files contain the same Futhark values.  The
files must be formatted using the general Futhark data format that is
used by all other executable and tools (such as
:ref:`futhark-dataset(1)`).  All discrepancies will be reported.  This
is in contrast to :ref:`futhark-test(1)`, which only reports the first
one.

futhark dev options... PROGRAM
------------------------------

A Futhark compiler development command, intentionally undocumented and
intended for use in developing the Futhark compiler, not for
programmers writing in Futhark.

SEE ALSO
========

futhark-opencl(1), futhark-c(1), futhark-py(1), futhark-pyopencl(1), futhark-dataset(1), futhark-doc(1), futhark-test(1), futhark-bench(1)
