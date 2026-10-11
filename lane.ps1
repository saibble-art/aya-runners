# AYA'S LANE. The single definition, dot-sourced by everything that needs it.
#
# This file exists because the lane was originally written out twice, once in
# sweep.ps1 and once in verify-lane.ps1. A safety check that keeps its own copy
# of the thing it is checking will eventually verify a list nobody uses. One
# definition, two consumers.
#
#   . C:\Users\saraa\.aya\lane.ps1
#   $allow = Get-AyaAllowList -DraftsOn:$true
#   $deny  = Get-AyaDenyList  -DraftsOn:$true

function Get-AyaAllowList {
    param([bool]$DraftsOn = $false)

    # Auto-approve list. NOTE: this does NOT restrict what is reachable.
    # Verified 2026-08-09: tools left off this list are still available.
    # The deny list is the actual boundary.
    $t = @(
        'Read'
        'mcp__claude_ai_Microsoft_365__outlook_email_search'
        'mcp__claude_ai_Microsoft_365__outlook_calendar_search'
        'mcp__claude_ai_Google_Calendar__list_events'
        'mcp__claude_ai_Google_Calendar__list_calendars'
        'mcp__claude_ai_Slack__slack_search_public_and_private'
        # Read the #fabiale dev channel directly. Added 2026-08-14 after a
        # week of dev updates and security flags went unseen because the
        # sweep only searched mentions of Sara.
        'mcp__claude_ai_Slack__slack_read_channel'
        'mcp__claude_ai_Slack__slack_search_channels'
        # GoHighLevel read tools, so Aya sees the pipeline without a prompt.
        # Writes stay denied in the deny list. Sara approved read 2026-08-10.
        'mcp__ghl__get_location'
        'mcp__ghl__get_pipelines'
        'mcp__ghl__search_opportunities'
        'mcp__ghl__get_opportunity'
        'mcp__ghl__search_contacts'
        'mcp__ghl__get_contacts'
        'mcp__ghl__get_contact'
        'mcp__ghl__get_all_tasks'
        'mcp__ghl__get_calendar_events'
        'mcp__ghl__list_calendars'
        'mcp__ghl__list_workflows'
        'mcp__ghl__list_transactions'
        'mcp__ghl__get_conversation'
        'mcp__ghl__get_messages'
        'mcp__ghl__search_conversations'
        'mcp__ghl__get_custom_fields'
        'mcp__ghl__get_email_templates'
    )
    if ($DraftsOn) {
        # A draft is not a send. These write to the drafts folder only.
        $t += 'mcp__claude_ai_Microsoft_365__outlook_create_reply_draft'
        $t += 'mcp__claude_ai_Microsoft_365__outlook_create_reply_all_draft'
        $t += 'mcp__claude_ai_Microsoft_365__outlook_create_draft'
    }
    return $t
}

function Get-AyaDenyList {
    param([bool]$DraftsOn = $false)

    $d = @(
        # Local tools. Aya reads files and nothing else.
        'Bash', 'PowerShell', 'Write', 'Edit', 'NotebookEdit'
        'Agent', 'Workflow', 'Artifact', 'Skill', 'DesignSync'
        'RemoteTrigger', 'PushNotification', 'SendMessage'
        'Task*', 'Cron*', 'EnterWorktree', 'ExitWorktree'
        'WebFetch', 'WebSearch'
        # Monitor starts a background shell process, so it is a shell in
        # disguise. Caught only because the verifier asked what could change
        # state rather than trusting that the obvious names were the whole list.
        'Monitor'

        # GoHighLevel: READ allowed, all writes denied (Sara approved read
        # access 2026-08-10). She runs her whole business on GHL and needs Aya
        # to see the pipeline. Every get_/list_/search_ tool is reachable. Every
        # tool that changes CRM state is denied by verb, so this ages correctly:
        # a new read tool is automatically allowed, a new write tool is
        # automatically blocked.
        #
        # Note: the GHL API cannot create workflows at all, that is UI-only. So
        # even add_contact_to_workflow (denied here) is about enrolling contacts,
        # not building automations. Workflows are built via Claude in Chrome
        # from a spec Aya writes, and left in draft.
        'mcp__ghl__create_*'
        'mcp__ghl__update_*'
        'mcp__ghl__delete_*'
        'mcp__ghl__add_*'
        'mcp__ghl__remove_*'
        'mcp__ghl__upsert_*'
        'mcp__ghl__send_*'
        'mcp__ghl__edit_*'

        # Whole servers the sweep has no business touching. Denying a server
        # is stronger and ages better than denying its verbs one at a time.
        'mcp__claude_ai_Gamma__*'
        'mcp__claude_ai_Google_Drive__*'
        'mcp__claude_ai_Higgsfield__*'
        'mcp__claude_ai_ClickUp__*'
        'mcp__claude_ai_Notion__*'
        'mcp__claude_ai_Dart__*'
        'mcp__claude_ai_n8n__*'
        'mcp__claude_ai_Gmail__*'

        # Microsoft 365: everything that sends, deletes, or mutates.
        # outlook_send* covers send_mail AND send_draft, the two that put mail
        # in flight. outlook_delete* covers delete_draft, because deleting
        # Sara's drafts is not Aya's to do.
        'mcp__claude_ai_Microsoft_365__outlook_send*'
        'mcp__claude_ai_Microsoft_365__outlook_forward*'
        'mcp__claude_ai_Microsoft_365__outlook_delete*'
        'mcp__claude_ai_Microsoft_365__outlook_trash*'
        'mcp__claude_ai_Microsoft_365__outlook_untrash*'
        'mcp__claude_ai_Microsoft_365__outlook_batch*'
        'mcp__claude_ai_Microsoft_365__outlook_modify*'
        'mcp__claude_ai_Microsoft_365__outlook_set_vacation'
        'mcp__claude_ai_Microsoft_365__outlook_create_event'
        'mcp__claude_ai_Microsoft_365__outlook_update_event'
        'mcp__claude_ai_Microsoft_365__outlook_respond_to_event'
        'mcp__claude_ai_Microsoft_365__outlook_create_filter'
        'mcp__claude_ai_Microsoft_365__outlook_delete_filter'
        'mcp__claude_ai_Microsoft_365__outlook_create_label'
        'mcp__claude_ai_Microsoft_365__outlook_update_label'
        'mcp__claude_ai_Microsoft_365__sharepoint_*'
        'mcp__claude_ai_Microsoft_365__teams_*'

        # Google Calendar: read only. Aya proposes a plan, she never books it.
        'mcp__claude_ai_Google_Calendar__create*'
        'mcp__claude_ai_Google_Calendar__update*'
        'mcp__claude_ai_Google_Calendar__delete*'
        'mcp__claude_ai_Google_Calendar__respond*'

        # Slack: read only.
        'mcp__claude_ai_Slack__slack_send*'
        'mcp__claude_ai_Slack__slack_create*'
        'mcp__claude_ai_Slack__slack_update*'
        'mcp__claude_ai_Slack__slack_add*'
        'mcp__claude_ai_Slack__slack_schedule*'
    )

    # When drafting is off, the draft tools are denied outright rather than
    # merely left unlisted, because unlisted does not mean unreachable.
    if (-not $DraftsOn) {
        $d += 'mcp__claude_ai_Microsoft_365__outlook_create_draft'
        $d += 'mcp__claude_ai_Microsoft_365__outlook_create_reply*'
        $d += 'mcp__claude_ai_Microsoft_365__outlook_update_draft'
    }
    return $d
}
