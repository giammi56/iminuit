# cython: embedsignature=True, c_string_type=str, c_string_encoding=ascii
# distutils: language = c++
"""IPython Minuit class definition.
"""
from __future__ import (absolute_import, division, print_function,
                        unicode_literals)
from warnings import warn
from libc.math cimport sqrt
from libcpp.string cimport string
from libcpp.cast cimport dynamic_cast
from cython.operator cimport dereference as deref
from iminuit.util import *
from iminuit.iminuit_warnings import (InitialParamWarning,
                                      HesseFailedWarning)
from iminuit.latex import LatexFactory
from iminuit import _plotting

include "Minuit2.pxi"
include "Minuit2Struct.pxi"

cimport numpy as np
import numpy as np
np.import_array()

__all__ = ['Minuit']

# Our wrappers
ctypedef FCNGradientBase* FCNGradientBasePtr
ctypedef IMinuitMixin* IMinuitMixinPtr
ctypedef PythonGradientFCN* PythonGradientFCNPtr

cdef class Minuit:
    # Standard stuff

    cdef readonly object fcn
    """Cost function (usually a chi^2 or likelihood function)"""

    cdef readonly object grad_fcn
    """Gradient function of the cost function"""

    cdef bint use_array_call
    """Whether to pass parameters as numpy array to cost function"""

    # TODO: remove or expose?
    # cdef readonly object varname #:variable names

    cdef readonly object pos2var
    """Map variable position to name"""

    cdef readonly object var2pos
    """Map variable name to position"""

    # Initial settings
    cdef object initial_value  #:hold initial values
    cdef object initial_error  #:hold initial errors
    cdef object initial_limit  #:hold initial limits
    cdef object initial_fix  #:hold initial fix state

    # C++ object state
    cdef FCNBase*pyfcn  #:FCN
    cdef MnApplication*minimizer  #:migrad
    cdef FunctionMinimum*cfmin  #:last migrad result
    #:last parameter state(from hesse/migrad)
    cdef MnUserParameterState*last_upst

    # PyMinuit compatible fields

    cdef public double errordef
    """Amount of change in FCN that defines 1 :math:`sigma` error.

    Default value is 1.0. `errordef` should be 1.0 for :math:`\chi^2` cost
    function and 0.5 for negative log likelihood function.

    This parameter is sometimes called ``UP`` in the MINUIT docs.
    """

    cdef public double tol
    """Tolerance.

    One of the MIGRAD convergence criteria is ``edm < edm_max``,
    where ``edm_max`` is calculated as ``edm_max = 0.0001 * tol * UP``.
    """

    cdef public unsigned int strategy
    """Strategy integer code.

    - 0 fast
    - 1 default
    - 2 slow but accurate
    """

    cdef public print_level
    """Print level.

    - 0: quiet
    - 1: print stuff the end
    - 2: 1+fit status during call

    Yes I know the case is wrong but this is to keep it compatible with PyMinuit.
    """

    cdef readonly bint throw_nan
    """Raise runtime error if function evaluate to nan."""

    # PyMinuit compatible interface

    cdef readonly object parameters
    """Parameter name tuple"""

    cdef readonly object args
    """Parameter value tuple"""

    cdef readonly object values
    """Parameter values (dict: name -> value)"""

    cdef readonly object errors
    """Parameter parabolic errors (dict: name -> error)"""

    cdef readonly object covariance
    """Covariance matrix (dict (name1, name2) -> covariance).

    .. seealso:: :meth:`matrix`
    """

    cdef readonly double fval
    """Last evaluated FCN value

    .. seealso:: :meth:`get_fmin`
    """

    cdef readonly int ncalls
    """Number of FCN call of last migrad / minos / hesse run."""

    cdef readonly double edm
    """Estimated distance to minimum.

    .. seealso:: :meth:`get_fmin`
    """

    cdef readonly object merrors
    """MINOS errors (dict).

    Using this method is not recommended.
    It was added only for PyMinuit compatibility.
    Use :meth:`get_merrors` instead, which returns a dictionary of
    name -> :ref:`minos-error-struct` instead.

    Dictionary entries for each parameter:

    * (name,1.0) -> upper error
    * (name,-1.0) -> lower error
    """

    cdef readonly object gcc
    """Global correlation coefficients (dict : name -> gcc)"""

    cdef public object fitarg
    """Current Minuit state in form of a dict.

    * name -> value
    * error_name -> error
    * fix_name -> fix
    * limit_name -> (lower_limit, upper_limit)

    This is very useful when you want to save the fit parameters and
    re-use them later. For example,::

        m = Minuit(f, x=1)
        m.migrad()
        fitarg = m.fitarg

        m2 = Minuit(f, **fitarg)
    """

    cdef readonly object narg
    """Number of arguments"""

    cdef public object merrors_struct
    """MINOS error calculation information (dict name -> struct)"""

    cdef public object frontend
    """Minuit frontend.

    TODO: link to description.
    """

    def __init__(self, fcn,
                 throw_nan=False, pedantic=True,
                 frontend=None, forced_parameters=None, print_level=1,
                 errordef=None, grad_fcn=None, use_array_call=False,
                 **kwds):
        """
        Construct minuit object from given *fcn*

        **Arguments:**

            **fcn**, the function to be optimized, is the only required argument.

            Two kinds of function signatures are understood.

            a) Parameters passed as positional arguments

            The function has several positional arguments, one for each fit
            parameter. Example::

                def func(a, b, c): ...

            The parameters a, b, c must accept a real number.

            iminuit automagically detects parameters names in this case.
            More information about how the function signature is detected can
            be found in :ref:`function-sig-label`

            b) Parameters passed as Numpy array

            The function has a single argument which is a Numpy array.
            Example::

                def func(x): ...

            Pass the keyword `use_array_call=True` to use this signature. For
            more information, see "Parameter Keyword Arguments" further down.

            If you work with array parameters a lot, have a look at the static
            initializer method :meth:`from_array_func`, which adds some
            convenience and safety to this use case.

        **Builtin Keyword Arguments:**

            - **throw_nan**: set fcn to raise RuntimeError when it
              encounters *nan*. (Default False)

            - **pedantic**: warns about parameters that do not have initial
              value or initial error/stepsize set.

            - **frontend**: Minuit frontend. There are two builtin frontends.

                1. ConsoleFrontend is designed to print out to terminal.

                2. HtmlFrontend is designed to give a nice output in an
                   IPython notebook session.

              By Default, Minuit switches to HtmlFrontend automatically if it
              is called in IPython session. It uses ConsoleFrontend otherwise.

            - **forced_parameters**: tell Minuit not to do function signature
              detection and use this argument instead. (Default None
              (automagically detect signature))

            - **print_level**: set the print_level for this Minuit. 0 is quiet.
              1 print out at the end of migrad/hesse/minos.

            - **errordef**: Optional. Amount of increase in fcn to be defined
              as 1 :math:`\sigma`. If None is given, it will look at
              `fcn.default_errordef()`. If `fcn.default_errordef()` is not
              defined or
              not callable iminuit will give a warning and set errordef to 1.
              Default None(which means errordef=1 with a warning).

            - **grad_fcn**: Optional. Provide a function that calculates the
              gradient analytically and returns an iterable object with one
              element for each dimension. If None is given minuit will
              calculate the gradient numerically. (Default None)

            - **use_array_call**: Optional. Set this to true if your function
              signature accepts a single numpy array of the parameters. You
              need to also pass the `forced_parameters` keyword then to
              explicitly name the parameters.

        **Parameter Keyword Arguments:**

            Similar to PyMinuit. iminuit allows user to set initial value,
            initial stepsize/error, limits of parameters and whether
            parameter should be fixed or not by passing keyword arguments to
            Minuit.

            This is best explained through examples::

                def f(x, y):
                    return (x-2)**2 + (y-3)**2

            * Initial value(varname)::

                #initial value for x and y
                m = Minuit(f, x=1, y=2)

            * Initial step size/error(fix_varname)::

                #initial step size for x and y
                m = Minuit(f, error_x=0.5, error_y=0.5)

            * Limits (limit_varname=tuple)::

                #limits x and y
                m = Minuit(f, limit_x=(-10,10), limit_y=(-20,20))

            * Fixing parameters::

                #fix x but vary y
                m = Minuit(f, fix_x=True)

            .. note::

                Tips: You can use python dictionary expansion to
                programmatically change the fitting arguments.

                ::

                    kwdarg = dict(x=1., error_x=0.5)
                    m = Minuit(f, **kwdarg)

                You can also obtain fit arguments from Minuit object
                to reuse it later too. *fitarg* will be automatically
                updated to the minimum value and the corresponding error when
                you ran migrad/hesse::

                    m = Minuit(f, x=1, error_x=0.5)
                    my_fitarg = m.fitarg
                    another_fit = Minuit(f, **my_fitarg)

        """
        if use_array_call and forced_parameters is None:
            raise KeyError("use_array_call=True requires that forced_parameters is set")

        args = describe(fcn) if forced_parameters is None \
            else forced_parameters
        self.narg = len(args)
        self._check_extra_args(args, kwds)

        if pedantic: self.pedantic(args, kwds)

        self.fcn = fcn
        self.grad_fcn = grad_fcn
        self.use_array_call = use_array_call

        self.frontend = self._auto_frontend() if frontend is None else frontend

        # Maintain 2 dictionaries to easily convert between
        # parameter names and position
        self.pos2var = {i: k for i, k in enumerate(args)}
        self.var2pos = {k: i for i, k in enumerate(args)}

        self.args, self.values, self.errors = None, None, None

        self.initial_value = {x: kwds.get(x, 0.) for x in args}
        self.initial_error = {x: kwds.get("error_" + x, 1.) for x in args}
        self.initial_limit = {x: kwds.get("limit_" + x, None) for x in args}
        self.initial_fix = {x: kwds.get("fix_" + x, False) for x in args}

        self.pyfcn = NULL
        self.minimizer = NULL
        self.cfmin = NULL
        self.last_upst = NULL

        if errordef is None:
            default_errordef = getattr(fcn, 'default_errordef', None)
            if not callable(default_errordef):
                if pedantic:
                    warn(InitialParamWarning(
                        'errordef is not given. Default to 1.'))
                self.errordef = 1.0
            else:
                self.errordef = default_errordef()
        else:
            self.errordef = errordef
        self.tol = 0.1
        self.strategy = 1
        self.print_level = print_level
        self.throw_nan = throw_nan

        self.parameters = args
        self.args = tuple(self.initial_value[k] for k in args)
        self.values = {k: self.initial_value[k] for k in args}
        self.errors = {k: self.initial_error[k] for k in args}
        self.covariance = None
        self.fval = 0.
        self.ncalls = 0
        self.edm = 1.
        self.merrors = {}
        self.gcc = None

        self.fitarg = {}
        self.fitarg.update(self.initial_value)
        self.fitarg.update({'error_' + k: v for k, v in self.initial_error.items()})
        self.fitarg.update({'limit_' + k: v for k, v in self.initial_limit.items()})
        self.fitarg.update({'fix_' + k: v for k, v in self.initial_fix.items()})

        self.merrors_struct = {}


    @classmethod
    def from_array_func(cls, fcn, start, error=None, limit=None, fix=None,
                        name=None, **kwds):
        """
        Construct minuit object from given *fcn* and start sequence.

        This is an alternative named constructor for the minuit object. It is
        more convenient to use for functions that accept a numpy array.

        **Arguments:**

            **fcn**: The function to be optimized. Must accept a single
            parameter that is a numpy array.

                def func(x): ...

            **start**: Sequence of numbers. Starting point for the
            minimization.

        **Keyword arguments:**

            **error**: Optional sequence of numbers. Initial step sizes.
            Scalars are automatically broadcasted to the length of the
            start sequence.

            **limit**: Optional sequence of limits that restrict the range in
            which a parameter is varied by minuit. Limits can be set in
            several ways. With inf = float("infinity") we get:

            - No limit: None, (-inf, inf), (None, None)

            - Lower limit: (x, None), (x, inf) [replace x with a number]

            - Upper limit: (None, x), (-inf, x) [replace x with a number]

            A single limit is automatically broadcasted to the length of the
            start sequence.

            **fix**: Optional sequence of boolean values. Whether to fix a
            parameter to the starting value.

            **name**: Optional sequence of parameter names. If names are not
            specified, the parameters are called x0, ..., xN.

            All other keywords are forwarded to :class:`Minuit`, see
            its documentation.

        **Example:**

            A simple example function is passed to Minuit. It accept a numpy
            array of the parameters. Initial starting values and error
            estimates are given::

                import numpy as np

                def f(x):
                    mu = (2, 3)
                    return np.sum((x-mu)**2)

                # error is automatically broadcasted to (0.5, 0.5)
                m = Minuit.from_array_func(f, (2, 3),
                                           error=0.5)

        """
        npar = len(start)
        pnames = name if name is not None else ["x%i"%i for i in range(npar)]
        kwds["forced_parameters"] = pnames
        kwds["use_array_call"] = True
        if error is not None:
            if np.isscalar(error):
                error = np.ones(npar) * error
            else:
                if len(error) != npar:
                    raise RuntimeError("length of error sequence does "
                                       "not match start sequence")
        if limit is not None:
            if (len(limit) == 2 and
                np.isscalar(limit[0]) and
                np.isscalar(limit[1])):
                limit = [limit for i in range(npar)]
            else:
                if len(limit) != npar:
                    raise RuntimeError("length of limit sequence does "
                                       "not match start sequence")
        for i, name in enumerate(pnames):
            kwds[name] = start[i]
            if error is not None:
                kwds["error_" + name] = error[i]
            if limit is not None:
                kwds["limit_" + name] = limit[i]
            if fix is not None:
                kwds["fix_" + name] = fix[i]
        return Minuit(fcn, **kwds)


    def migrad(self, int ncall=10000, resume=True, int nsplit=1, precision=None):
        """Run migrad.

        Migrad is an age-tested(over 40 years old, no kidding), super
        robust and stable minimization algorithm. It even has
        `wiki page <http://en.wikipedia.org/wiki/MINUIT>`_.
        You can read how it does the magic at
        `here <http://wwwasdoc.web.cern.ch/wwwasdoc/minuit/minmain.html>`_.

        **Arguments:**

            * **ncall**: integer (approximate) maximum number of call before
              migrad stop trying. Default 10000.

            * **resume**: boolean indicating whether migrad should resume from
              the previous minimizer attempt(True) or should start from the
              beginning(False). Default True.

            * **split**: split migrad in to *split* runs. Max fcn call
              for each run is ncall/nsplit. Migrad stops when it found the
              function minimum to be valid or ncall is reached. This is useful
              for getting progress. However, you need to make sure that
              ncall/nsplit is large enough. Otherwise, migrad will think
              that the minimum is invalid due to exceeding max call
              (ncall/nsplit). Default 1(no split).

            * **precision**: override miniut own's internal precision.

        **Return:**

            :ref:`function-minimum-sruct`, list of :ref:`minuit-param-struct`
        """
        #construct new fcn and migrad if
        #it's a clean state or resume=False
        cdef MnUserParameterState*ups = NULL
        cdef MnStrategy*strat = NULL

        if self.print_level > 0:
            self.frontend.print_banner('MIGRAD')

        if not resume or self.is_clean_state():
            self.construct_FCN()
            if self.minimizer is not NULL: del self.minimizer
            ups = self.initialParameterState()
            strat = new MnStrategy(self.strategy)

            if self.grad_fcn is None:
                self.minimizer = new MnMigrad(
                    deref(<FCNBase*> self.pyfcn),
                    deref(ups), deref(strat)
                )
            else:
                self.minimizer = new MnMigrad(
                    deref(<FCNGradientBase*> self.pyfcn),
                    deref(ups), deref(strat)
                )

            del ups;
            ups = NULL
            del strat;
            strat = NULL

        self.minimizer.Minimizer().Builder().SetPrintLevel(self.print_level)

        cdef PythonGradientFCNPtr grad_fcn_ptr = NULL
        if not resume:
            dynamic_cast[IMinuitMixinPtr](self.pyfcn).resetNumCall()
            grad_fcn_ptr = dynamic_cast[PythonGradientFCNPtr](self.pyfcn)
            if grad_fcn_ptr:
                grad_fcn_ptr.resetNumGrad()

        del self.cfmin  #remove the old one

        #this returns a real object need to copy
        ncall_round = round(1.0 * (ncall) / nsplit)
        assert (ncall_round > 0)
        totalcalls = 0
        first = True

        if precision is not None:
            self.minimizer.SetPrecision(precision)

        while (first) or \
                (not self.cfmin.IsValid() and totalcalls < ncall):
            first = False
            self.cfmin = call_mnapplication_wrapper(
                deref(self.minimizer), ncall_round, self.tol)
            del self.last_upst
            self.last_upst = new MnUserParameterState(self.cfmin.UserState())
            totalcalls += ncall_round  #self.cfmin.NFcn()
            if self.print_level > 1 and nsplit != 1: self.print_fmin()

        del self.last_upst
        self.last_upst = new MnUserParameterState(self.cfmin.UserState())
        self.refreshInternalState()

        if self.print_level > 0:
            self.print_fmin()

        return self.get_fmin(), self.get_param_states()

    def hesse(self, unsigned int maxcall=1000):
        """Run HESSE.

        HESSE estimates error matrix by the `second derivative at the minimim
        <http://en.wikipedia.org/wiki/Hessian_matrix>`_. This error matrix
        is good if your :math:`\chi^2` or likelihood profile is parabolic at
        the minimum. From my experience, most of the simple fits are.

        :meth:`minos` makes no parabolic assumption and scan the likelihood
        and give the correct error asymmetric error in all cases(Unless your
        likelihood profile is utterly discontinuous near the minimum). But,
        it is much more computationally expensive.

        **Returns:**

            list of :ref:`minuit-param-struct`
        """

        cdef MnHesse*hesse = NULL
        cdef MnUserParameterState upst
        if self.print_level > 0: self.frontend.print_banner('HESSE')
        if self.cfmin is NULL:
            raise RuntimeError('Run migrad first')
        hesse = new MnHesse(self.strategy)
        if self.grad_fcn is None:
            upst = hesse.call(
                deref(<FCNBase*> self.pyfcn),
                self.cfmin.UserState(),
                maxcall
            )
        else:
            upst = hesse.call(
                deref(<FCNGradientBase*> self.pyfcn),
                self.cfmin.UserState(),
                maxcall
            )
        if not upst.HasCovariance():
            warn("HESSE Failed. Covariance and GlobalCC will not be available",
                 HesseFailedWarning)
        del self.last_upst
        self.last_upst = new MnUserParameterState(upst)
        self.refreshInternalState()
        del hesse

        if self.print_level > 0:
            self.print_param()
            self.print_matrix()

        return self.get_param_states()

    def minos(self, var = None, sigma = 1., unsigned int maxcall=1000):
        """Run minos for parameter *var*.

        If *var* is None it runs minos for all parameters

        **Arguments:**

            - **var**: optional variable name. Default None.(run minos for
              every variable)
            - **sigma**: number of :math:`\sigma` error. Default 1.0.

        **Returns:**

            Dictionary of varname to :ref:`minos-error-struct`
            if minos is requested for all parameters.

        """
        if self.pyfcn is NULL or self.cfmin is NULL:
            raise RuntimeError('Minos require function to be at the minimum.'
                               ' Run migrad first.')
        cdef unsigned int index = 0
        cdef MnMinos*minos = NULL
        cdef MinosError mnerror
        cdef char*name = NULL
        cdef double oldup = self.pyfcn.Up()
        self.pyfcn.SetErrorDef(oldup * sigma * sigma)
        if self.print_level > 0: self.frontend.print_banner('MINOS')
        if not self.cfmin.IsValid():
            raise RuntimeError(('Function mimimum is not valid. Make sure'
                                ' migrad converge first'))
        if var is not None and var not in self.parameters:
            raise RuntimeError('Specified parameters(%r) cannot be found'
                               ' in parameter list :' % var + str(self.parameters))

        varlist = [var] if var is not None else self.parameters

        fixed_param = self.list_of_fixed_param()
        for vname in varlist:
            index = self.cfmin.UserState().Index(vname)

            if vname in fixed_param:
                if var is not None:  #specifying vname but it's fixed
                    warn(RuntimeWarning(
                        'Specified variable name for minos is set to fixed'))
                    return None
                continue
            if self.grad_fcn is None:
                minos = new MnMinos(
                    deref(<FCNBase*> self.pyfcn),
                    deref(self.cfmin), self.strategy
                )
            else:
                minos = new MnMinos(
                    deref(dynamic_cast[FCNGradientBasePtr](self.pyfcn)),
                    deref(self.cfmin), self.strategy
                )
            mnerror = minos.Minos(index, maxcall)
            self.merrors_struct[vname] = minoserror2struct(mnerror)
            if self.print_level > 0:
                self.frontend.print_merror(
                    vname, self.merrors_struct[vname])
        self.refreshInternalState()
        del minos
        self.pyfcn.SetErrorDef(oldup)
        return self.merrors_struct

    def matrix(self, correlation=False, skip_fixed=True):
        """Error or correlation matrix in tuple or tuples format."""
        if self.last_upst is NULL:
            raise RuntimeError("Run migrad/hesse first")
        if not self.last_upst.HasCovariance():
            raise RuntimeError(
                "Covariance is not valid. May be the last Hesse call failed?")

        cdef MnUserCovariance mncov = self.last_upst.Covariance()
        cdef vector[MinuitParameter] mp = self.last_upst.MinuitParameters()

        if skip_fixed:
            ind = [i for i in range(mp.size()) if not mp[i].IsFixed()]
            def cov(i, j): return mncov.get(i, j)
        else:
            ind = range(mp.size())
            def cov(i, j):
                if mp[i].IsFixed() or mp[j].IsFixed():
                    return 0.0
                return mncov.get(i, j)

        if correlation:
            if skip_fixed:
                def cor(i, j): return cov(i, j) / sqrt(cov(i, i) * cov(j, j))
            else:
                def cor(i, j):
                    if i == j:
                        return 1.0
                    if mp[i].IsFixed() or mp[j].IsFixed(): return 0.0
                    return mncov.get(i, j) / sqrt(mncov.get(i, i) * mncov.get(j, j))
            ret = tuple(tuple(cor(i, j) for i in ind) for j in ind)
        else:
            ret = tuple(tuple(cov(i, j) for i in ind) for j in ind)

        return ret

    def print_matrix(self, **kwds):
        """Show error_matrix"""
        matrix = self.matrix(correlation=True)
        vnames = self.list_of_vary_param()
        self.frontend.print_matrix(vnames, matrix, **kwds)

    def latex_matrix(self):
        """Build :class:`LatexFactory` object with the correlation matrix
        """
        matrix = self.matrix(correlation=True)
        vnames = self.list_of_vary_param()
        return LatexFactory.build_matrix(vnames, matrix)

    def np_matrix(self, correlation=False, skip_fixed=True):
        """Error or correlation matrix in numpy array format.

        The name of this function was chosen to be analogous to :meth:`matrix`,
        it returns the same information in a different format. For
        documentation on the arguments, please see :meth:`matrix`.

        **Returns:**

            2D ``numpy.ndarray`` of shape (N,N) (not a ``numpy.matrix``).
        """
        matrix = self.matrix(correlation=correlation, skip_fixed=skip_fixed)
        return np.array(matrix, dtype=np.double)

    def np_values(self):
        """Parameter values in numpy array format.

        Fixed parameters are included, the order follows :attr:`parameters`.

        **Returns:**

            ``numpy.ndarray`` of shape (N,).
        """
        return np.array(self.args, dtype=np.double)

    def np_errors(self):
        """Hesse parameter errors in numpy array format.

        Fixed parameters are included, the order follows :attr:`parameters`.

        **Returns:**

            ``numpy.ndarray`` of shape (N,).
        """
        a = np.empty(len(self.parameters), dtype=np.double)
        for i, k in enumerate(self.parameters):
            a[i] = self.errors[k]
        return a

    def np_merrors(self):
        """Minos parameter errors in numpy array format.

        Fixed parameters are included, the order follows :attr:`parameters`.

        The format of the produced array follows matplotlib conventions, as
        in ``matplotlib.pyplot.errorbar``. The shape is (2, N) for N
        parameters. The first row represents the downward error as a positive
        offset from the center. Likewise, the second row represents the
        upward error as a positive offset from the center.

        **Returns:**

            ``numpy.ndarray`` of shape (2, N).
        """
        # array format follows matplotlib conventions, see pyplot.errorbar
        a = np.empty((2, len(self.parameters)), dtype=np.double)
        for i, k in enumerate(self.parameters):
            a[0, i] = -self.merrors[(k, -1.0)]
            a[1, i] = self.merrors[(k, 1.0)]
        return a

    def np_covariance(self):
        """Covariance matrix in numpy array format.

        Fixed parameters are included, the order follows :attr:`parameters`.

        **Returns:**

            ``numpy.ndarray`` of shape (N,N) (not a ``numpy.matrix``).
        """
        return self.np_matrix(correlation=False, skip_fixed=False)

    def is_fixed(self, vname):
        """Check if variable *vname* is (initially) fixed"""
        if vname not in self.parameters:
            raise RuntimeError('Cannot find %s in list of variables.' % vname)
        cdef unsigned int index = self.var2pos[vname]
        if self.last_upst is NULL:
            return self.initial_fix[vname]
        else:
            return self.last_upst.MinuitParameters()[index].IsFixed()

    #dealing with frontend conversion
    def print_param(self, **kwds):
        """Print current parameter state.

        Extra keyword arguments will be passed to frontend.print_param.
        """
        # fetches the initial state if migrad was not run
        p = self.get_param_states()
        self.frontend.print_param(p, self.merrors_struct, **kwds)

    def latex_param(self):
        """build :class:`iminuit.latex.LatexTable` for current parameter"""
        p = self.get_param_states()
        return LatexFactory.build_param_table(p, self.merrors_struct)

    def print_initial_param(self, **kwds):
        """Print initial parameters"""
        p = self.get_initial_param_states()
        self.frontend.print_param(p, {}, **kwds)

    def latex_initial_param(self):
        """Build :class:`iminuit.latex.LatexTable` for initial parameter"""
        p = self.get_initial_param_states()
        return LatexFactory.build_param_table(p, {})

    def print_fmin(self):
        """Print current function minimum state"""
        #cdef MnUserParameterState ust = MnUserParameterState(
        #                               self.cfmin.UserState())
        if self.cfmin is NULL:
            raise RuntimeError("Function minimum has not been calculated.")
        sfmin = cfmin2struct(self.cfmin)
        ncalls = 0 if self.pyfcn is NULL else dynamic_cast[IMinuitMixinPtr](self.pyfcn).getNumCall()

        self.frontend.print_hline()
        self.frontend.print_fmin(sfmin, self.tol, ncalls)
        self.print_param()
        self.frontend.print_hline()

    def print_all_minos(self):
        """Print all minos errors (and its states)"""
        for vname in self.list_of_vary_param():
            if vname in self.merrors_struct:
                self.frontend.print_merror(vname, self.merrors_struct[vname])

    def set_up(self, double errordef):
        """Alias for :meth:`set_errordef`"""
        self.set_errordef(errordef)

    def set_errordef(self, double errordef):
        """Set error parameter 1 for :math:`\chi^2` and 0.5 for log likelihood.

        See page 37 of http://hep.fi.infn.it/minuit.pdf
        """
        # TODO: try to get a HTML link for this again.
        # It was this before, but that is currently broken.
        # http://wwwasdoc.web.cern.ch/wwwasdoc/minuit/node31.html
        self.errordef = errordef
        if self.pyfcn is not NULL:
            self.pyfcn.SetErrorDef(errordef)

    def set_strategy(self, value):
        """Set strategy.

        - 0 = fast
        - 1 = default
        - 2 = slow but accurate
        """
        self.strategy = value

    def set_print_level(self, lvl):
        """Set print level.

        - 0 quiet
        - 1 normal
        - 2 paranoid
        - 3 really paranoid
        """
        self.print_level = lvl
        if self.minimizer:
            self.minimizer.Minimizer().Builder().SetPrintLevel(self.print_level)

    def get_fmin(self):
        """Current FunctionMinimum Struct"""
        return cfmin2struct(self.cfmin) if self.cfmin is not NULL else None

    # Expose internal state using various structs

    def get_param_states(self):
        """List of current MinuitParameter Struct for all parameters"""
        if self.last_upst is NULL:
            return self.get_initial_param_states()
        up = self.last_upst
        cdef vector[MinuitParameter] vmps = up.MinuitParameters()
        return [minuitparam2struct(vmps[i]) for i in range(vmps.size())]

    def get_initial_param_states(self):
        """List of current MinuitParameter Struct for all parameters"""
        up = self.initialParameterState()
        cdef vector[MinuitParameter] vmps = up.MinuitParameters()
        return [minuitparam2struct(vmps[i]) for i in range(vmps.size())]

    def get_merrors(self):
        """Dictionary of varname-> MinosError Struct"""
        return self.merrors_struct

    def get_num_call_fcn(self):
        """Total number of calls to FCN (not just the last operation)"""
        cdef IMinuitMixinPtr ptr = dynamic_cast[IMinuitMixinPtr](self.pyfcn)
        return ptr.getNumCall() if ptr else 0

    def get_num_call_grad(self):
        """Total number of calls to Gradient (not just the last operation)"""
        cdef PythonGradientFCNPtr ptr = dynamic_cast[PythonGradientFCNPtr](self.pyfcn)
        return ptr.getNumGrad() if ptr else 0

    def migrad_ok(self):
        """Check if minimum is valid."""
        return self.cfmin is not NULL and self.cfmin.IsValid()

    def matrix_accurate(self):
        """Check if covariance (of the last migrad) is accurate"""
        return self.last_upst is not NULL and \
               self.cfmin is not NULL and \
               self.cfmin.HasAccurateCovar()

    def list_of_fixed_param(self):
        """List of (initially) fixed parameters"""
        return [v for v in self.parameters if self.initial_fix[v]]

    def list_of_vary_param(self):
        """List of (initially) float varying parameters"""
        return [v for v in self.parameters if not self.initial_fix[v]]


    # Various utility functions

    cdef construct_FCN(self):
        """Construct or re-construct FCN"""
        del self.pyfcn
        if self.grad_fcn is None:
            self.pyfcn = new PythonFCN(
                self.fcn,
                self.use_array_call,
                self.errordef,
                self.parameters,
                self.throw_nan)
        else:
            self.pyfcn = new PythonGradientFCN(
                self.fcn,
                self.grad_fcn,
                self.use_array_call,
                self.errordef,
                self.parameters,
                self.throw_nan)

    def is_clean_state(self):
        """Check if minuit is in a clean state, ie. no migrad call"""
        return self.pyfcn is NULL and \
               self.minimizer is NULL and self.cfmin is NULL

    cdef void clear_cobj(self):
        #clear C++ internal state
        del self.pyfcn;
        self.pyfcn = NULL
        del self.minimizer;
        self.minimizer = NULL
        del self.cfmin;
        self.cfmin = NULL
        del self.last_upst;
        self.last_upst = NULL

    def __dealloc__(self):
        self.clear_cobj()

    def pedantic(self, parameters, kwds):
        for vn in parameters:
            if vn not in kwds:
                warn(('Parameter %s does not have initial value. '
                      'Assume 0.') % (vn), InitialParamWarning)
            if 'error_' + vn not in kwds and 'fix_' + param_name(vn) not in kwds:
                warn(('Parameter %s is floating but does not '
                      'have initial step size. Assume 1.') % (vn),
                     InitialParamWarning)
        for vlim in extract_limit(kwds):
            if param_name(vlim) not in parameters:
                warn(('%s is given. But there is no parameter %s. '
                      'Ignore.' % (vlim, param_name(vlim)), InitialParamWarning))
        for vfix in extract_fix(kwds):
            if param_name(vfix) not in parameters:
                warn(('%s is given. But there is no parameter %s. \
                    Ignore.' % (vfix, param_name(vfix)), InitialParamWarning))
        for verr in extract_error(kwds):
            if param_name(verr) not in parameters:
                warn(('%s float. But there is no parameter %s. \
                    Ignore.') % (verr, param_name(verr)), InitialParamWarning)

    def mnprofile(self, vname, bins=30, bound=2, subtract_min=False):
        """Calculate minos profile around the specified range.

        That is Migrad minimum results with **vname** fixed at various places within **bound**.

        **Arguments:**

            * **vname** name of variable to scan

            * **bins** number of scanning bins. Default 30.

            * **bound**
              If bound is tuple, (left, right) scanning bound.
              If bound is\\ a number, it specifies how many :math:`\sigma`
              symmetrically from minimum (minimum+- bound* :math:`\sigma`).
              Default 2

            * **subtract_min** subtract_minimum off from return value. This
              makes it easy to label confidence interval. Default False.

        **Returns:**

            bins(center point), value, migrad results
        """
        if vname not in self.parameters:
            raise ValueError('Unknown parameter %s' % vname)

        if isinstance(bound, (int, long, float)):
            if not self.matrix_accurate():
                warn('Specify nsigma bound but error '
                     'but error matrix is not accurate.')
            start = self.values[vname]
            sigma = self.errors[vname]
            bound = (start - bound * sigma, start + bound * sigma)

        values = np.linspace(*bound, bins, dtype=np.double)
        results = np.empty(bins, dtype=np.double)
        migrad_status = np.empty(bins, dtype=np.bool)
        cdef double vmin = float("infinity")
        for i, v in enumerate(values):
            fitparam = self.fitarg.copy()
            fitparam[vname] = v
            fitparam['fix_%s' % vname] = True
            m = Minuit(self.fcn, print_level=0,
                       pedantic=False, forced_parameters=self.parameters,
                       **fitparam)
            m.migrad()
            migrad_status[i] = m.migrad_ok()
            if not m.migrad_ok():
                warn(('Migrad fails to converge for %s=%f') % (vname, v))
            results[i] = m.fval
            if m.fval < vmin: vmin = m.fval

        if subtract_min:
            results -= vmin

        return values, results, migrad_status

    def draw_mnprofile(self, vname, bins=30, bound=2, subtract_min=False,
                       band=True, text=True):
        """Draw minos profile around the specified range.

        It is obtained by finding Migrad results with **vname** fixed
        at various places within **bound**.

        **Arguments:**

            * **vname** variable name to scan

            * **bins** number of scanning bin. Default 30.

            * **bound**
              If bound is tuple, (left, right) scanning bound.
              If bound is a number, it specifies how many :math:`\sigma`
              symmetrically from minimum (minimum+- bound* :math:`\sigma`).
              Default 2.

            * **subtract_min** subtract_minimum off from return value. This
              makes it easy to label confidence interval. Default False.

            * **band** show green band to indicate the increase of fcn by
              *errordef*. Default True.

            * **text** show text for the location where the fcn is increased
              by *errordef*. This is less accurate than :meth:`minos`.
              Default True.

        **Returns:**

            bins(center point), value, migrad results

        .. plot:: pyplots/draw_mnprofile.py
            :include-source:
        """
        x, y, s = self.mnprofile(vname, bins, bound, subtract_min)
        return _plotting.draw_profile(self, vname, x, y, s,
                                      band=band, text=text)

    def profile(self, vname, bins=100, bound=2, args=None, subtract_min=False):
        """Calculate cost function profile around specify range.

        **Arguments:**

            * **vname** variable name to scan

            * **bins** number of scanning bin. Default 100.

            * **bound**
              If bound is tuple, (left, right) scanning bound.
              If bound is a number, it specifies how many :math:`\sigma`
              symmetrically from minimum (minimum+- bound* :math:`\sigma`).
              Default 2

            * **subtract_min** subtract_minimum off from return value. This
              makes it easy to label confidence interval. Default False.

        **Returns:**

            bins(center point), value

        .. seealso::

            :meth:`mnprofile`
        """
        if subtract_min and self.cfmin is NULL:
            raise RuntimeError("Request for minimization "
                               "subtraction but no minimization has been done. "
                               "Run migrad first.")

        if isinstance(bound, (int, long, float)):
            start = self.values[vname]
            sigma = self.errors[vname]
            bound = (start - bound * sigma,
                     start + bound * sigma)

        # center value
        val = np.linspace(*bound, bins, dtype=np.double)
        result = np.empty(bins, dtype=np.double)
        cdef int pos = self.var2pos[vname]
        cdef list arg = list(self.args if args is None else args)
        cdef int n = val.shape[0]
        for i in range(n):
            arg[pos] = val[i]
            result[i] = self.fcn(*arg)
        if subtract_min:
            result -= self.cfmin.Fval()
        return val, result

    def draw_profile(self, vname, bins=100, bound=2, args=None,
                     subtract_min=False, band=True, text=True):
        """A convenient wrapper for drawing profile using matplotlib.

        .. note::
            This is not a real minos profile. It's just a simple 1D scan.
            The number shown on the plot is taken from the green band.
            They are not minos error. To get a real minos profile call
            :meth:`mnprofile` or :meth:`draw_mnprofile`

        **Arguments:**

            In addition to argument listed on :meth:`profile`. draw_profile
            take these addition argument:

            * **band** show green band to indicate the increase of fcn by
              *errordef*. Note again that this is NOT minos error in general.
              Default True.

            * **text** show text for the location where the fcn is increased
              by *errordef*. This is less accurate than :meth:`minos`
              Note again that this is NOT minos error in general. Default True.

        .. seealso::
            :meth:`mnprofile`
            :meth:`draw_mnprofile`
            :meth:`profile`
        """
        x, y = self.profile(vname, bins, bound, args, subtract_min)
        x, y, s = _plotting.draw_profile(self, vname, x, y,
                                         band=band, text=text)
        return x, y

    def contour(self, x, y, bins=20, bound=2, args=None, subtract_min=False):
        """2D contour scan.

        return contour of migrad result obtained by fixing all
        others parameters except **x** and **y** which are let to varied.

        **Arguments:**

            - **x** variable name for X axis of scan

            - **y** variable name for Y axis of scan

            - **bound**
              If bound is 2x2 array [[v1min,v1max],[v2min,v2max]].
              If bound is a number, it specifies how many :math:`\sigma`
              symmetrically from minimum (minimum+- bound*:math:`\sigma`).
              Default 2

            - **subtract_min** subtract_minimum off from return value. This
              makes it easy to label confidence interval. Default False.

        **Returns:**

            x_bins, y_bins, values

            values[y, x] <-- this choice is so that you can pass it
            to through matplotlib contour()

        .. seealso::

            :meth:`mncontour`

        .. note::

            If `subtract_min=True`, the return value has the minimum subtracted
            off. The value on the contour can be interpreted *loosely* as
            :math:`i^2 \\times \\textrm{up}` where i is number of standard
            deviation away from the fitted value *WITHOUT* taking into account
            correlation with other parameters that's fixed.

        """

        if subtract_min and self.cfmin is NULL:
            raise RuntimeError("Request for minimization "
                               "subtraction but no minimization has been done. "
                               "Run migrad first.")

        if isinstance(bound, (int, long, float)):
            x_start = self.values[x]
            x_sigma = self.errors[x]
            x_bound = (x_start - bound * x_sigma, x_start + bound * x_sigma)
            y_start = self.values[y]
            y_sigma = self.errors[y]
            y_bound = (y_start - bound * y_sigma, y_start + bound * y_sigma)
        else:
            x_bound = bound[0]
            y_bound = bound[1]

        x_val = np.linspace(*x_bound, bins)
        y_val = np.linspace(*y_bound, bins)

        cdef int x_pos = self.var2pos[x]
        cdef int y_pos = self.var2pos[y]

        cdef list arg = list(self.args if args is None else args)

        result = np.empty((bins, bins), dtype=np.double)
        for i, x in enumerate(x_val):
            arg[x_pos] = x
            for j, y in enumerate(y_val):
                arg[y_pos] = y
                result[i, j] = self.fcn(*arg)

        if subtract_min:
            result -= self.cfmin.Fval()

        return x_val, y_val, result

    def mncontour(self, x, y, int numpoints=20, sigma=1.0):
        """Minos contour scan.

        A proper n **sigma** contour scan. This is the line
        where the minimum of fcn  with x,y is fixed at points on the line and
        letting the rest of variable varied is change by **sigma** * errordef^2
        . The calculation is very very expensive since it has to run migrad
        at various points.

        .. note::
            See http://wwwasdoc.web.cern.ch/wwwasdoc/minuit/node7.html

        **Arguments:**

            - **x** string variable name of the first parameter

            - **y** string variable name of the second parameter

            - **numpoints** number of points on the line to find. Default 20.

            - **sigma** number of sigma for the contour line. Default 1.0.

        **Returns:**

            x minos error struct, y minos error struct, contour line

            contour line is a list of the form
            [[x1,y1]...[xn,yn]]

        """
        if self.pyfcn is NULL or self.cfmin is NULL:
            raise ValueError('Run Migrad first')

        cdef unsigned int ix = self.var2pos[x]
        cdef unsigned int iy = self.var2pos[y]

        vary_param = self.list_of_vary_param()

        if x not in vary_param or y not in vary_param:
            raise ValueError('mncontour has to be run on vary parameters.')

        cdef double oldup = self.pyfcn.Up()
        self.pyfcn.SetErrorDef(oldup * sigma * sigma)

        cdef auto_ptr[MnContours] mnc = auto_ptr[MnContours](NULL)
        if self.grad_fcn is None:
            mnc = auto_ptr[MnContours](
                new MnContours(deref(<FCNBase*> self.pyfcn),
                               deref(self.cfmin),
                               self.strategy))
        else:
            mnc = auto_ptr[MnContours](
                new MnContours(deref(dynamic_cast[FCNGradientBasePtr](self.pyfcn)),
                               deref(self.cfmin),
                               self.strategy))
        cdef ContoursError cerr = mnc.get().Contour(ix, iy, numpoints)

        xminos = minoserror2struct(cerr.XMinosError())
        yminos = minoserror2struct(cerr.YMinosError())

        self.pyfcn.SetErrorDef(oldup)

        return xminos, yminos, cerr.Points()  #using type coersion here

    def mncontour_grid(self, x, y, bins=100, nsigma=2, numpoints=20,
                       int sigma_res=4, edges=False):
        """Compute gridded minos contour.

        **Arguments:**

            - **x**, **y** parameter name

            - **bins** number of bins in the grid. The boundary of the grid is
              selected automatically by the minos error computed. Default 100.

            - **nsigma** number of sigma to draw. Default 2

            - **numpoints** number of points to calculate mncontour for each
              sigma points(there are sigma_res*nsigma total)

            - **sigma_res** number of sigma level to calculate MnContours

            - **edges** Return bin edges instead of mid value(pass True if you
              want to draw it using pcolormesh)

        **Returns:**

            xgrid, ygrid, sigma, rawdata

            rawdata is tuple of (x,y,sigma_level)

        .. seealso::

            :meth:`draw_mncontour`

        .. plot:: pyplots/draw_mncontour.py
            :include-source:

        """
        return _plotting.mncontour_grid(self, x, y, numpoints,
                                        nsigma, sigma_res, bins, edges)

    def draw_mncontour(self, x, y, bins=100, nsigma=2,
                       numpoints=20, sigma_res=4):
        """Draw minos contour.

        **Arguments:**

            - **x**, **y** parameter name

            - **bins** number of bin in contour grid.

            - **nsigma** number of sigma contour to draw

            - **numpoints** number of points to calculate for each contour

            - **sigma_res** number of sigma level to calculate MnContours.
              Default 4.

        **Returns:**

            x, y, gridvalue, contour

            gridvalue is interorlated nsigma
        """
        return _plotting.draw_mncontour(self, x, y, bins, nsigma,
                                        numpoints, sigma_res)

    def draw_contour(self, x, y, bins=20, bound=2, args=None,
                     show_sigma=False):
        """Convenience wrapper for drawing contours.

        The argument is the same as :meth:`contour`.
        If `show_sigma=True`(Default), the label on the contour lines will show
        how many :math:`\sigma` away from the optimal value instead of raw value.

        .. note::

            Like :meth:`contour`, the error shown on the plot is not strictly the
            1 :math:`\sigma` contour since the other parameters are fixed.

        .. seealso::

            :meth:`contour`
            :meth:`mncontour`
        """
        return _plotting.draw_contour(self, x, y, bins,
                                      bound, args, show_sigma)

    cdef refreshInternalState(self):
        """Refresh internal state attributes.

        These attributes should be in a function instead
        but kept here for PyMinuit compatibility
        """
        cdef vector[MinuitParameter] mpv
        cdef MnUserCovariance cov
        cdef double tmp = 0
        if self.last_upst is not NULL:
            mpv = self.last_upst.MinuitParameters()
            self.values = {}
            self.errors = {}
            self.args = []
            for i in range(mpv.size()):
                self.args.append(mpv[i].Value())
                self.values[mpv[i].Name()] = mpv[i].Value()
                self.errors[mpv[i].Name()] = mpv[i].Error()
            self.args = tuple(self.args)
            self.fitarg.update(self.values)
            self.fitarg.update({'error_' + k: v for k, v in self.errors.items()})
            vary_param = self.list_of_vary_param()
            if self.last_upst.HasCovariance():
                cov = self.last_upst.Covariance()
                self.covariance = \
                    {(v1, v2): cov.get(i, j) \
                     for i, v1 in enumerate(vary_param) \
                     for j, v2 in enumerate(vary_param)}
            else:
                self.covariance = None
            self.fval = self.last_upst.Fval()
            self.ncalls = self.last_upst.NFcn()
            self.edm = self.last_upst.Edm()
            self.gcc = None
            if self.last_upst.HasGlobalCC() and self.last_upst.GlobalCC().IsValid():
                self.gcc = {v: self.last_upst.GlobalCC().GlobalCC()[i] for \
                            i, v in enumerate(self.list_of_vary_param())}

        self.merrors = {(k, 1.0): v.upper
                        for k, v in self.merrors_struct.items()}
        self.merrors.update({(k, -1.0): v.lower
                             for k, v in self.merrors_struct.items()})

    cdef MnUserParameterState*initialParameterState(self) except *:
        """Construct parameter state from initial array.

        Caller is responsible for cleaning up the pointer.
        """
        cdef MnUserParameterState*ret = new MnUserParameterState()
        cdef object lb
        cdef object ub
        for v in self.parameters:
            ret.Add(v, self.initial_value[v], self.initial_error[v])

        for v in self.parameters:
            if self.initial_limit[v] is not None:
                inf = float("infinity")
                lb, ub = self.initial_limit[v]
                if lb is None:
                    lb = -inf
                if ub is None:
                    ub = inf
                if lb >= ub:
                    raise ValueError(
                        'limit for parameter %s is invalid. %r' % (v, (lb, ub)))
                if lb == -inf and ub == inf:
                    pass
                elif ub == inf:
                    ret.SetLowerLimit(v, lb)
                elif lb == -inf:
                    ret.SetUpperLimit(v, ub)
                else:
                    ret.SetLimits(v, lb, ub)
                #need to set value again
                #taking care of internal/external transformation
                ret.SetValue(v, self.initial_value[v])
                ret.SetError(v, self.initial_error[v])

        for v in self.parameters:
            if self.initial_fix[v]:
                ret.Fix(v)
        return ret

    def _auto_frontend(self):
        """Determine frontend automatically.

        Use HTML frontend in IPython sessions and console frontend otherwise.
        """
        try:
            __IPYTHON__
            from iminuit.frontends.html import HtmlFrontend
            return HtmlFrontend()
        except NameError:
            from iminuit.frontends.console import ConsoleFrontend
            return ConsoleFrontend()

    def _check_extra_args(self, parameters, kwd):
        """Check keyword arguments to find unwanted/typo keyword arguments"""
        fixed_param = set('fix_' + p for p in parameters)
        limit_param = set('limit_' + p for p in parameters)
        error_param = set('error_' + p for p in parameters)
        for k in kwd.keys():
            if k not in parameters and \
                            k not in fixed_param and \
                            k not in limit_param and \
                            k not in error_param:
                raise RuntimeError(
                    ('Cannot understand keyword %s. May be a typo?\n'
                     'The parameters are %r') % (k, parameters))
