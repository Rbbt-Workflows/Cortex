require 'scout-ai'

# ==========================================================================
# Cortex helpers: workflow-facing delegation to the lib modules
# ==========================================================================
#
# Declared inside module Cortex by workflow.rb (helpers need the Workflow
# context: they are instance methods of the workflow's execution scope).
# This file documents that layout and holds nothing else; each helper
# delegates 1:1 to the corresponding Cortex.* module function so the
# behaviour and naming of the historical helpers is preserved exactly.
#
# The helper declarations themselves live in workflow.rb right after
# `module Cortex ... extend Workflow`; see there for the list.
