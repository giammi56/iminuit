# Makefile with some convenient quick ways to do common things

PROJECT = iminuit
PYTHON ?= python3

default_target: build

help:
	@echo ''
	@echo ' iminuit available make targets:'
	@echo ''
	@echo '     help             Print this help message'
	@echo ''
	@echo '     build            Build inplace (the default)'
	@echo '     clean            Remove all generated files'
	@echo '     test             Run tests'
	@echo '     cov              Run tests and write coverage report'
	@echo '     doc              Run Sphinx to generate HTML docs'
	@echo ''
	@echo ' More info:'
	@echo ''
	@echo ' * iminuit code: https://github.com/scikit-hep/iminuit'
	@echo ' * iminuit docs: https://iminuit.readthedocs.org/'
	@echo ''

clean:
	rm -rf build htmlcov doc/_build src/iminuit/_libiminuit.cpp src/iminuit/_libiminuit*.so tutorial/.ipynb_checkpoints iminuit.egg-info .pytest_cache src/iminuit/__pycache__ src/iminuit/tests/__pycache__ tutorial/__pycache__ .coverage .eggs .ipynb_checkpoints dist

build: src/iminuit/_libiminuit.so

test: build
	$(PYTHON) -m pytest

cov: build
	@echo "Note: This only shows the coverage in pure Python."
	$(PYTHON) -m pytest --cov src/iminuit --cov-report html

doc: doc/_build/html/index.html

flake8: build
	@$(PYTHON) -m flake8 src/$(PROJECT)

src/iminuit/_libiminuit.so: $(wildcard src/iminuit/*.pyx src/iminuit/*.pxi)
	$(PYTHON) setup.py build_ext --inplace

doc/_build/html/index.html: build $(wildcard src/iminuit/*.pyx src/iminuit/*.pxi src/iminuit/*.py src/iminuit/**/*.py doc/*.rst)
	{ cd doc; make html; }

## pylint is garbage, also see https://lukeplant.me.uk/blog/posts/pylint-false-positives/#running-total
# pylint: build
# 	@$(PYTHON) -m pylint -E src/$(PROJECT) -d E0611,E0103,E1126 -f colorized \
# 	       --msg-template='{C}: {path}:{line}:{column}: {msg} ({symbol})'
