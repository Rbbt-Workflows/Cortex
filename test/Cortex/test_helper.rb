require 'test/unit'
# Load the full workflow (module Cortex extends Workflow) BEFORE the scratch
# path maps are installed: workflow.rb evaluates `CORTEX = Scout.var.cortex` at
# load time, which caches a located Path against the real repo root, and task
# bodies (Step machinery) run with CWD = the installed workflow dir.
require 'scout-ai'

ROOT    = File.expand_path(File.join(File.dirname(__FILE__), '..', '..'))
SCRATCH = File.join(ROOT, 'tmp', 'entity_test_var')
LIBDIR  = File.join(SCRATCH, 'lib')
USERDIR = File.join(SCRATCH, 'user')

require File.expand_path(File.join(ROOT, 'workflow'))
