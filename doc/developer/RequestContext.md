# Request-context checkpoints

Cortex artifact writes and edits accept an optional `checkpoint:` keyword. The
artifact version record includes a normalized `checkpoint` object only when
call-scoped identity fields are present. Existing writes without context keep
the historical metadata shape.

The normalization is available as `Cortex::RequestContext.checkpoint(value)`
(or `checkpoint_for`). It accepts a projected hash or a `Step` with an attached
runtime context, and recognizes `call_id`/`tool_call_id` and
`function_name`/`tool_name`. It does not derive an identity from a Step path,
process, timestamp, or global state.

The artifact tasks use the accessor against their current Step. This is useful
when a caller has attached a context before task execution, for example with
`Cortex::RequestContext.attach(step, context)`. Attachment is runtime-only and
does not alter task inputs, memoization, Step identity, or result addresses.

This is Cortex-side plumbing, not end-to-end propagation. The installed
Scout-AI dispatcher may construct and execute a workflow Step inside
`LLM.call_workflow` before returning it to Cortex; post-return attachment
cannot cover that execution. A dependency-side pre-execution hook (or an
upstream equivalent that attaches the per-call context before `job.exec`) is
still required for automatic exported-tool propagation. Cortex does not claim
that this release provides that propagation.

The focused request-context tests include direct pre-execution attachment and
artifact metadata checks. They do not exercise the unavailable dependency-side
hook.

## ScoutCoder note

# ScoutCoder: call identity fields must be supplied by the dependency-side
# tool-call loop; Cortex should normalize optional fields but must not invent
# identities or put runtime context into workflow inputs.
