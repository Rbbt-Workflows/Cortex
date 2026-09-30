# Request-context provenance: pre-exec Scout-AI integration handoff

## Status

Cortex-side artifact checkpoint behavior is locally testable and the focused request-context suite passes. End-to-end runtime propagation into `export_exec` is **not** established: Scout-AI's current `LLM.call_workflow` executes export tasks before returning the Step, but Cortex's adapter currently attaches context only after that method returns. This note specifies the narrow upstream change required; no installed Scout-AI gem was modified.

Repository Git status could not be established in the active checkout: `.git` points to `../.git/modules/Cortex`, which is absent in the available filesystem, and Git reports `fatal: not a git repository`. Do not infer a clean tree from that failure.

## Observed Cortex behavior

- `lib/Cortex/request_context.rb` projects request metadata, duplicates the Step/dependency tree to keep caller-specific state off the cached Step, attaches metadata in `@cortex_request_context`, and provides `checkpoint` access. The metadata does not become a task input.
- The `LLM.call_workflow` adapter currently invokes `super` first and attaches the context to the returned Step afterwards.
- Scout-AI `LLM.call_workflow` runs `job.exec` inside its `exec_exports` / `exec_type == 'exec'` branch before it returns. Therefore the post-return adapter cannot supply checkpoint context to that execution.
- Cortex's `cortex_write` / `cortex_edit` pass `RequestContext.checkpoint(self)` to the artifact writer. `write_artifact` adds the normalized checkpoint to the new artifact-version record only when nonempty; older versions without it remain valid.
- `LLM::RequestContext.project` intentionally filters unsafe `conversation` values. Safe `save_file`, `call_id`, and function-name fields can be checkpointed when supplied. Do not claim the full conversation contents or identifier is persisted by this integration.

## Minimal Scout-AI patch specification

In `lib/scout/llm/tools/call.rb`, after `call_id_name_and_arguments` resolves `tool_call_id` and `function_name`, make a fresh projected context for this tool call and pass it to `call_workflow` in the Workflow/String dispatch branches:

```ruby
tool_request_context = LLM::RequestContext.project(request_context || {})
tool_request_context = {} unless Hash === tool_request_context
tool_request_context = tool_request_context.merge(
  call_id: tool_call_id, function_name: function_name
)
```

Use `request_context: tool_request_context` for the two `call_workflow` calls (the resolved String workflow and the Workflow object). Do not mutate the caller's `request_context` or add these fields to `function_arguments`.

In `lib/scout/llm/tools/workflow.rb`, after `job = workflow.job(task_name.to_sym, jobname, parameters)` and **before** the `exec_exports` / `exec_type` branch, call a documented preparation hook:

```ruby
job = prepare_workflow_job(job, request_context)
```

Provide a default identity implementation on `LLM`:

```ruby
def self.prepare_workflow_job(job, _request_context = nil)
  job
end
```

The hook must run before every possible `job.exec`, and before returning non-export Steps. Cortex should override only this narrow hook and call `Cortex::RequestContext.attach(job, request_context)` there. Keeping preparation as a per-call hook preserves runtime-only state and avoids a global/thread-local context or changes to Step inputs and identity. Test the hook for exec and non-exec paths in Scout-AI itself.

The exact hook API/naming is a proposal for the upstream patch, not an existing Scout-AI API. Do not merge a Cortex monkeypatch that assumes this hook exists before Scout-AI provides it.

## Cortex-side verification

`test/Cortex/test_request_context.rb` includes a focused test that pre-attaches context to a `cortex_write` Step, asserts that the Step path is unchanged, executes it, and verifies checkpoint metadata in the artifact version sidecar. This validates Cortex's pre-attached export behavior, not the missing Scout-AI dispatch hook or an end-to-end tool call.

Reproduce with:

```sh
ruby -Itest test/Cortex/test_request_context.rb
```

Observed final result in the current checkout: **11 tests, 41 assertions, 0 failures, 0 errors**.

## Next action

Apply and test the hook and per-tool call context propagation in the Scout-AI source checkout (not its installed gem), then add an integration test dispatching an `export_exec` tool call through `LLM.process_calls` and verifying the artifact checkpoint's safe call metadata. Until that is complete, end-to-end context presence before `export_exec` remains unverified and should be treated as absent.
