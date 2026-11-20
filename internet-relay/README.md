# AiboOS Internet Relay (prototype)

A real HTTPS inbox for AiboOS IDs over mobile data and Wi-Fi, using Cloudflare Workers + D1.
It is **not deployed** until you connect your Cloudflare account and publish it.

## Deploy

1. Install Node.js 20+ and run `npx wrangler login` in this folder.
2. Run `npx wrangler d1 create aiboos-relay`.
3. Replace `REPLACE_WITH_YOUR_D1_DATABASE_ID` in `wrangler.toml` with the UUID returned by that command.
4. Run `npx wrangler d1 execute aiboos-relay --remote --file=schema.sql`.
5. Run `npx wrangler deploy`.
6. In the AiboOS **Messages → Internet Messaging** settings, paste the printed **https://...workers.dev** URL on both phones.

People can search Aibo IDs worldwide. Messages are queued on the server until the other device fetches them. The receiving device acknowledges delivery; only then can the sender show **Delivered**. Users control their display names and optional profile photos.

## Security & important limitations

- This is a development prototype, **not end-to-end encrypted**. The server stores plaintext messages, sender/recipient IDs, and optional photos. Do not use for sensitive information.
- The 7-digit IDs are **not proof of a person's identity**. A proper account-verification and anti-impersonation system is still needed.
- Registering a device requires a random 256-bit device key; the server stores a SHA-256 hash, not the key. The native client should store the key in iOS Keychain.
- Network API uses TLS (HTTPS). Add moderation, reporting/blocking, stronger anti-spam, database retention policies, and operational monitoring before public launch.
- The free tier has usage limits. Messages are polled while the app is open; there are **no push notifications while the app is closed**.
- This relay is **text messaging only**. Worldwide voice calling needs an additional WebRTC signaling and TURN service. Local nearby Aibo Calls remain separate.
- Incoming messages are only acknowledged after the client receives them; delivery does **not** mean the user has read the message.
- Deleting an account is possible with authenticated `DELETE /v1/account`, but there is no in-app delete UI yet.

## Routes

- `GET /v1/health` — connectivity check
- `POST /v1/register` — create/update profile; the server assigns a unique Aibo ID
- `GET /v1/profile/:id` — find user by Aibo ID
- `POST /v1/messages` — queue a message
- `GET /v1/sync?cursor=N&receiptSince=T` — receive messages and receipts
- `POST /v1/ack` — acknowledge receipt on recipient's device
- `DELETE /v1/account` — delete account and messages

Every route except `health` and `register` requires the registered device key as `Authorization: Bearer <64 hexadecimal characters>`. Register also requires that key.
