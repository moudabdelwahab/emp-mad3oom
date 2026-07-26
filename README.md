WhatsApp Inbox Investigation Summary

We have an issue where incoming WhatsApp messages are no longer appearing in the Inbox, although the WhatsApp Cloud API integration had been working previously.

Current symptoms
Sending template messages still works.
Customers receive the template successfully.
Customers reply successfully.
However, the reply never appears in the Inbox.
Refreshing the page (F5) does not make the message appear either.

This strongly suggests the issue is not in the frontend rendering or Supabase Realtime.

Investigation already completed
Frontend

The following files were reviewed:

InboxPage.js
message-store.js
message-realtime.js
supabase-message-helper.js
message-normalizer.js

Result:

None of these files receive messages directly from Meta.
They only display records that already exist inside the messages table.

Therefore the Inbox frontend is not considered the root cause.

Database

The messages table was inspected.

Finding:

The last inbound message stored is from approximately one month ago.
No new incoming messages are being inserted.
Edge Functions

Reviewed:

whatsapp-webhook
meta-webhook
send-whatsapp

Previous investigation suggested there were no recent webhook executions, leading to the hypothesis that Meta was no longer delivering webhook events.

Initial hypothesis

The previous developer believed the problem was caused by the WABA not being subscribed to the application.

They concluded that the platform never executed:

POST /{waba-id}/subscribed_apps

and therefore reconnecting WhatsApp refreshed tokens but never restored webhook delivery.

Manual verification performed

We manually verified the Meta configuration.

Callback URL

The callback URL configured inside Meta is correct.

It points to:

https://srnelrdpqkcntbgudyto.supabase.co/functions/v1/whatsapp-webhook
Webhook subscriptions

The messages field is subscribed.

WABA subscription

We manually called:

GET /{waba-id}/subscribed_apps

using a valid access token.

The response was:

{
  "data": [
    {
      "whatsapp_business_api_data": {
        "id": "1510313544014876",
        "name": "business",
        "link": "https://wa.mad3oom.com/"
      }
    }
  ]
}

This confirms:

The application is already subscribed to the WABA.
Therefore the previous hypothesis about missing subscribed_apps is incorrect.
Current understanding

At this point we have confirmed:

Callback URL is correct.
Webhook "messages" subscription exists.
The application is subscribed to the WABA.
Frontend is only a consumer of database records.
No new rows are appearing inside the messages table.
Remaining possible causes

The investigation should continue from the webhook execution path.

Please verify:

Is Meta actually sending POST requests to the deployed webhook?
Does the deployed Edge Function receive those requests?
Is the deployed version different from the latest source code?
Does the webhook fail while resolving the integration?
Does the incoming phone_number_id exactly match the record stored in the integrations table?
Does the function exit early before inserting into messages?
Are there any runtime errors or swallowed exceptions inside the webhook?
Important

Please do not restart the investigation from scratch.

The Meta configuration has already been verified, and the WABA subscription has been confirmed.

The investigation should continue from the webhook execution flow until the point where a row should be inserted into the messages table.

The objective is to determine exactly where the execution stops.
