# AiboOS Internet Relay — access and encryption guide

## What this server does

AiboOS 1.8 automatically connects to the internet relay at https://aibomesgsystem.wwoolf21963.workers.dev. Each fresh installation generates a seven-digit AiboID and a private device credential. The app sends the ID and its chosen display name to the server , and retries when Wi-Fi or mobile data returns. An existing installation keeps its ID rather than making a new one every time. Another device can search for that ID, see its optional profile photo, and send a message. 

 A Cloudflare Hello World page is only a placeholder. 

## Step 1: Create message storage

 Open Workers & Pages, then D1 SQL Database. Create a database named aiboos-relay. Open its SQL editor. Copy and run the statements from internet-relay/schema.sql in the AiboOS GitHub repository. 

Return to the existing Worker named aibomesgsystem. Open Settings, then Bindings, and add a D1 Database binding. Its variable name must be exactly DB and its target must be the aiboos-relay database. Save or deploy the configuration. A Worker with no DB binding cannot register accounts or deliver messages.

## Step 2: Add the private encryption secret

AiboOS now encrypts new message bodies before storing them in D1 using AES-256-GCM. This requires a unique random encryption key controlled by the server owner. On a trusted device with Python available, generate one using:

 python3 -c "import secrets; print(secrets.token_hex(32))"

 Copy the value privately. In Cloudflare, open the aibomesgsystem Worker, find Settings, Variables and Secrets, then add a Secret named AIBO_MESSAGE_ENCRYPTION_KEY. Paste the generated value into its secret value, save, and deploy. Never paste the value into GitHub, a QR code, a screenshot, or a chat message. 

The key protects stored messages if someone obtains database contents without the Worker secret. It does not give end-to-end encryption: the Worker decrypts messages for authorized recipients. HTTPS protects traffic in transit. Keep a secure backup of the key; rotating or losing it without a migration makes older encrypted messages unreadable. Messages already stored as plaintext before this update are legacy records and are not retroactively protected.

## Step 3: Deploy the actual relay code

The messaging Worker is internet-relay/src/index.js. Deploy that file to your aibomesgsystem Worker, replacing the Hello World example. If you use Wrangler, run its login command in the internet-relay folder, create or select your D1 database, and replace REPLACE_WITH_YOUR_D1_DATABASE_ID in wrangler.toml with your real D1 database ID. Apply schema.sql to the remote database before deploying; local D1 data does not automatically become remote data.

You can instead paste the Worker JavaScript into the Cloudflare dashboard editor, provided the DB binding and secret are configured there. 

## Step 4: Check the connection

Open https://aibomesgsystem.wwoolf21963.workers.dev/v1/health in your browser. A healthy configured relay should return JSON reporting ok true and messageEncryption AES-256-GCM at rest. If it says Database binding missing, add DB. If it says Message encryption not configured, add the secret. If you see Hello World, the correct JavaScript has not been deployed. 

Next open AiboOS 1.8 on two separate devices or independent browser storage profiles. Do not use two tabs sharing the same storage if you want two distinct IDs. In Messages, note each device's ID. Set a display name and optional picture. Wait for Online. On the first device, search the second ID and send a harmless test message. The recipient must open AiboOS to retrieve it; the sender should show Sent before acknowledging delivery and Delivered only afterward. 

## Step 5: Erase an account safely

In AiboOS Settings, choose General, Transfer or Reset, then Erase All Content and Settings. The app requests authenticated deletion of its online account, AiboID, and queued messages before clearing local AiboOS storage. If the service is offline, it warns you and offers Cancel or Erase Phone Only. Choosing local-only erase cannot guarantee remote account removal. Automatic safety wipes after repeated failed passcodes attempt server deletion but must still wipe local data if the network is unavailable.

Deleting iOS itself, factory-resetting the phone outside AiboOS, or uninstalling the app cannot reliably run this online request. Those actions may leave an orphaned server account. 

## Important safety limits

Do not send sensitive information in the beta. Device credentials are stored locally, the server can decrypt delivered content, users lack end-to-end key verification, and security review is incomplete. Protect access to your Cloudflare account, back up the encryption key securely, and never share a single master credential with all phones. A 750-word password is unnecessary: strong randomly generated secrets and separate per-device credentials provide better access control.