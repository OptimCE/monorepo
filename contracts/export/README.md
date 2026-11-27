# Contrat d'export OptimCE — version 1.0

Ce dossier est la **source de vérité** du contrat qui relie le worker d'export
(crm-backend) aux services qui produisent chacun leur partie de l'archive. Il
contient les JSON Schemas des messages, du manifest et de l'enveloppe des
fichiers de données, plus des exemples valides.

Les services ne lisent pas ce dossier : chacun en garde une **copie identique**,
parce que la CI d'un sous-module ne voit pas la racine du monorepo.
`scripts/check-export-parity.sh` vérifie que les copies n'ont pas dérivé.

| Référence | Copie | Qui |
| --- | --- | --- |
| `schemas/` | `assets/export/schemas/` | crm-backend |
| `python/core/export/` (schémas compris) | `core/export/` | chaque annexe Python |
| `python/tests/export_kit/` | `tests/export_kit/` | chaque annexe Python |

Le kit Node n'a qu'un utilisateur, crm-backend : sa référence est
`crm-backend/src/shared/export/kit/`, sans copie ici.

```
contracts/export/
├── README.md                      ce document
├── schemas/
│   ├── common.schema.json         définitions partagées
│   ├── export-job-requested.schema.json
│   ├── export-request.schema.json
│   ├── export-part-done.schema.json
│   ├── export-part-failed.schema.json
│   ├── manifest.schema.json
│   ├── data-file.schema.json      enveloppe de chaque fichier JSON de données
│   └── files/<service>/<entity>.schema.json   (ajoutés avec chaque handler)
├── examples/                      un exemple valide par schéma
└── python/                        export-handler-kit Python (référence)
    ├── core/export/               copié tel quel dans chaque annexe
    └── tests/export_kit/          ses tests, copiés avec lui
```

## 1. Principes (rappel de la spec, ils priment)

1. L'export ne montre jamais plus que ce que le demandeur voit dans l'app au
   moment de la demande. Chaque service réutilise les fonctions ou requêtes de
   son API, jamais une règle propre à l'export.
2. Export utilisateur = les données **sur** lui, pas celles auxquelles il a accès.
3. Chaque service exporte ses propres données ; le worker ne lit aucune donnée
   métier, il ne connaît que ce contrat.
4. Pas d'export partiel silencieux : une partie en échec fait échouer le job.
5. Les exports sont éphémères (expiration, suppression, hors sauvegardes).
6. Aucun fichier ne transite par NATS : MinIO porte le contenu, NATS des
   identifiants, des clés d'objets et des compteurs.

## 2. Versionnage

`schemaVersion` vaut `MAJEUR.MINEUR` (aujourd'hui `1.0`) dans chaque message, le
manifest et chaque fichier de données.

- Un ajout compatible (champ optionnel, nouvelle valeur d'énumération côté
  émetteur seulement) incrémente le mineur.
- Tout le reste incrémente le majeur. Un service qui reçoit un majeur inconnu
  répond `export.part.failed` avec `unsupported_schema`.
- Les schémas sont stricts (`additionalProperties: false`) : un champ non
  déclaré est une erreur, pas une extension silencieuse.

## 3. NATS / JetStream

### Stream

| Paramètre | Valeur |
| --- | --- |
| Nom | `EXPORTS` |
| Sujets | `export.>` |
| Rétention | work-queue (chaque message est consommé une fois) |
| Stockage | fichier |
| `max_age` | 24 h |
| `duplicate_window` | 2 min |
| Propriétaire | crm-backend (le déclare et le réconcilie). Les annexes s'abonnent sans le déclarer et réessaient en arrière-plan tant qu'il n'existe pas, comme pour `core.evt.>` |

Les sujets `export.>` ne recouvrent aucun stream existant (`core.evt.>`,
`optimce.*`, `docgen.*`, `signature.event.*`).

### Sujets et consommateurs

| Sujet | Émetteur | Consommateur durable | Schéma |
| --- | --- | --- | --- |
| `export.job.requested` | crm-backend (API), après le commit | `export-worker-jobs` | `export-job-requested` |
| `export.request.<service>` | worker | `export-<service>` (dans le process API du service) | `export-request` |
| `export.part.done` | service | `export-worker-parts` | `export-part-done` |
| `export.part.failed` | service | `export-worker-parts` | `export-part-failed` |
| `export.erase.<service>` | — | — | réservé à l'effacement, non implémenté |

En work-queue, deux consommateurs ne peuvent pas filtrer des sujets qui se
recouvrent : `export-worker-parts` filtre exactement `export.part.done` et
`export.part.failed`.

`Nats-Msg-Id` : `<partId>:<attempt>` pour une demande, `<partId>:<attempt>:done`
ou `:failed` pour une réponse, `<exportId>:requested` pour un job. Le
dédoublonnage JetStream absorbe ainsi une republication immédiate.

### Règles

- **Ack explicite** seulement après l'écriture complète des fichiers dans MinIO
  et la publication de la réponse. `max_deliver` 5, backoff 10 s, 1 min, 5 min.
  Un handler long envoie `in_progress()` régulièrement pour ne pas être relivré
  pendant qu'il travaille.
- **Concurrence** : `max_ack_pending` = 1 sur le consommateur durable, donc une
  partie à la fois par service, toutes instances confondues.
- **Arrêt propre** : sur SIGTERM, le service cesse de consommer et renvoie `nak`
  pour la demande en cours.
- **Idempotence** : une fois tous ses fichiers écrits, le kit dépose sous le
  préfixe un marqueur `.export/done.json` qui contient la réponse `done`, puis
  publie cette réponse.
  - Une relivraison de la **même tentative** (ack perdu) republie le marqueur sans
    rien réécrire : réécrire changerait des fichiers que le worker lit peut-être
    déjà, et la nouvelle réponse serait jetée comme doublon (même `Nats-Msg-Id`).
  - Toute autre exécution (première, ou tentative plus récente) vide d'abord le
    préfixe, puis réécrit tout.
  - `.export/` est réservé au kit : aucun fichier de l'archive ne peut y être écrit,
    et le marqueur n'apparaît jamais dans `files`.
- **Erreurs** : une erreur transitoire (base ou MinIO indisponible) donne un `nak`
  et JetStream relivre (10 s, 1 min, 5 min). Si la 5e livraison échoue encore, le
  kit répond `export.part.failed` (`internal`) plutôt que de laisser le worker
  attendre son timeout. Une erreur non récupérable donne `export.part.failed` :
  - `scope_not_found` : communauté ou utilisateur inconnu du service ;
  - `forbidden` : le demandeur n'a plus les droits, relus au moment du traitement ;
  - `corrupt_data` : donnée incohérente, par exemple un objet référencé absent ;
  - `unsupported_schema` : majeur inconnu ;
  - `internal` : tout autre échec définitif.
- **Attempt** : la réponse reprend l'`attempt` de la demande. Le worker ignore
  une réponse dont l'`attempt` n'est pas le dernier publié, ou dont le job est
  déjà `failed` ou `expired`.
- **Timeout** : sans réponse 30 min après `requested_at`, le worker republie avec
  `attempt + 1`. Après 3 tentatives, la partie passe en `failed`.
- **Aucune donnée personnelle dans un message** : uniquement des identifiants,
  des clés d'objets et des compteurs. `errorDetail` est pour les opérateurs et ne
  cite jamais de contenu exporté. Les services ne journalisent que des
  identifiants.

### Identifiants

- `exportId` et `partId` sont des UUID générés par crm-backend
  (`export_job.id`, `export_part.id`).
- `scope.id` et `requester.userId` sont les identifiants Keycloak, que tous les
  services connaissent : le `sub` de l'utilisateur (`app_user.auth_user_id`) et
  l'id du groupe de la communauté (`community.auth_community_id`). Ce ne sont pas
  toujours des UUID (les seeds de test utilisent `auth0|admin`, `2`). Chaque
  service les traduit vers ses ids internes.

### Worker

Le worker (`crm-backend/src/export-worker.ts`, conteneur `crm-export-worker`) n'a
d'autre état que `export_job` et `export_part`. Chaque transition est une mise à
jour conditionnelle sur le statut attendu, donc un redémarrage reprend où il en
était, et un message tardif ne déplace jamais une ligne.

- **Démarrage** : sur `export.job.requested`, ou par le balayage d'un job resté
  `pending` plus de 30 s (annonce perdue).
- **Demande d'une partie** : la tentative est réservée (`attempts`), puis publiée,
  puis confirmée (`requested_at`). Une publication non confirmée est refaite au
  tick suivant, et le dédoublonnage JetStream absorbe le double.
- **Assemblage** : un job à la fois, dès que toutes ses parties sont `done`. Le
  bail est `updated_at`, renouvelé pendant l'écriture : un assemblage dont le
  worker est mort est repris après 2 min. Trois essais au plus.
- **Tick** (60 s) : jobs `pending` oubliés, publications à refaire, parties sans
  réponse (30 min, 3 tentatives), garde-fou 24 h, expiration des archives.
- **Fichiers** : les parties sont supprimées dès l'archive écrite, ou dès l'échec.
  Une réponse `done` arrivée après l'échec ou l'expiration voit ses fichiers
  supprimés.

Codes d'erreur d'un job en `failed` (`export_job.error_code`, pour les opérateurs) :

| Code | Cause |
| --- | --- |
| `scope_not_found`, `forbidden`, `corrupt_data`, `unsupported_schema`, `internal` | repris de l'`export.part.failed` d'un service |
| `invalid_part` | une partie écrit hors de son préfixe ou de son dossier, ou référence un bucket non autorisé |
| `corrupt_part` | un fichier n'a pas la taille ou l'empreinte que sa partie déclarait |
| `corrupt_data` | un objet référencé par une partie n'existe pas |
| `part_timeout` | un service n'a pas répondu après 3 tentatives |
| `job_timeout` | export encore actif 24 h après la demande |
| `assembly_failed` | archive non écrite après 3 essais |
| `invalid_manifest` | le manifeste produit n'est pas valide (défaut du worker) |

## 4. Stockage MinIO

Bucket `exports`, séparé des buckets de documents.

| Clé | Contenu | Durée de vie |
| --- | --- | --- |
| `parts/<exportId>/<service>/…` | fichiers écrits par un service | supprimés dès que le ZIP est écrit ; ILM à 2 jours en filet |
| `archives/<exportId>/optimce-export-<user\|community>-<AAAAMMJJ>.zip` | archive finale | supprimée à `expires_at` (7 j) par le worker ; ILM à 8 jours en filet |

Les parties et les archives sont sous des préfixes de tête distincts parce
qu'une règle ILM ne filtre que sur un préfixe de tête.

| Compte | Droits |
| --- | --- |
| `export-<service>` (un par service) | `PutObject`, `GetObject` (pour son marqueur), `DeleteObject` sur `exports/parts/*/<service>/*` ; `ListBucket` limité à ce préfixe |
| `export-worker` | `GetObject`, `DeleteObject`, `ListBucket` sur `exports/*` ; `PutObject` sur `exports/archives/*` ; `GetObject` en lecture seule sur `crm-files` et `optimce-documents` (fichiers référencés) |
| `export-download` | `GetObject` sur `exports/archives/*`, pour signer les URL présignées (300 s) |

Le bucket `exports` est exclu des sauvegardes et de toute réplication.

En dev, `minio-init` crée tout cela avec `minio/export/provision.sh` (bash pur :
l'image `mc` n'a ni sed ni grep). Les secrets viennent de `EXPORT_<NOM>_SECRET` et le
script refuse de créer un compte sans secret. Chaque service reçoit son compte via
`EXPORT_STORAGE_ACCESS_KEY` / `EXPORT_STORAGE_SECRET_KEY`, et non via son compte de
stockage habituel.

## 5. Archive

```text
optimce-export-community-20261114.zip
├── manifest.json
├── index.html                 (export utilisateur uniquement)
├── crm/
│   ├── members.json
│   ├── consumptions/<EAN>/<AAAA>.csv
│   └── documents/files/<documentId>-<nom>
├── signature/
│   ├── requests.json
│   └── files/…
└── <service>/…                un dossier par service de EXPORT_SERVICES
```

- **Un dossier par service**, au nom du service. Chaque `files[].path` et
  `references[].targetPath` commence par `<service>/` ; le worker refuse une
  partie qui écrit ailleurs.
- **`manifest.json`** (`manifest.schema.json`) liste chaque fichier réellement
  présent, références comprises, avec la taille et le sha256 lus par le worker.
- **Fichiers JSON** : UTF-8, un fichier par type d'entité,
  `<service>/<entity>.json`, dans l'enveloppe `data-file.schema.json`. La forme
  de chaque `items[]` est décrite par `schemas/files/<service>/<entity>.schema.json`.
  Identifiants stables (ids internes, EAN), dates ISO 8601 UTC.
- **CSV** pour les séries temporelles : UTF-8, virgule, ligne d'en-tête avec les
  unités (ex. `timestamp_utc,offtake_kwh,injection_kwh,shared_kwh`), un fichier
  par EAN et par année.
- **Documents** dans leur format d'origine, renvoyés en `references` : le
  service ne les recopie jamais, le worker les lit dans leur bucket.
- **`index.html`** : page autonome (CSS en ligne, sans JavaScript ni ressource
  externe), dans la langue du demandeur, générée par le worker depuis le
  manifest et les `labelKey` (`export.<service>.<compteur>`).

## 6. Propriété des données

Une table est exportée par un seul service :

- **crm_db** (DDL dans crm-backend) : par `crm`, même quand une annexe y écrit
  (`audit_log`, `notification`, `outbound_message`, `allocation_key`,
  `regulatory_link_status`…). C'est l'API de crm-backend qui les lit et les
  autorise.
- **Base locale d'une annexe** : par cette annexe.

| Service | Tables exportées | Tables non exportées (techniques ou de référence) |
| --- | --- | --- |
| `crm` | `app_user`, `community`, `community_user`, `community_subscription`, `user_member_link`, `member`, `individual`, `company`, `manager`, `address`, `meter`, `meter_data`, `meter_consumption`, `sharing_operation`, `sharing_operation_municipality`, `sharing_operation_key`, `sharing_op_consumption`, `allocation_key`, `iteration`, `consumer`, `document`, `user_member_invitation`, `gestionnaire_invitation`, `audit_log`, `notification`, `outbound_message`, `notification_preference`, `email_suppression`, `user_onboarding`, `regulatory_link_status` ; identité Keycloak (API admin) | `outbox_event`, `municipality`, `municipality_postal_code` |
| `signature` | `signature_request`, `signature_signer`, `signature_field`, `signature_revision`, `signature_event` | `schema_version` |
| `administrative-document` | `dossier`, `document`, `document_version`, `status_event`, `deadline`, `change`, `correspondence`, `inbound_address`, `inbound_mail`, `inbound_mail_attachment`, `digest_setting`, `piece_signature`, `version_check` | `schema_version`, `document_template`, `procedure_definition`, `deadline_rule`, `working_calendar`, `document_render`, `processed_event`, `module_activation` |
| `billing` | `tariff`, `billing_run`, `settlement_snapshot`, `invoice`, `invoice_line`, `credit_note`, `payment` | `schema_version`, `invoice_sequence` |
| `news-board` | `post`, `post_poll`, `post_poll_vote` | `schema_version` |
| `simulation-key` | `simulation`, `simulation_key_result`, `simulation_iteration_result`, `simulation_consumer_result` | `schema_version` |
| `allocation-key-generation` | `generation`, `allocation_key_generated`, `iteration_generated`, `consumer_generated` | `schema_version` |
| `live-data` | `device`, `measurement` (utilisateur), `rollup_community_day` et `rollup_operation_day` (communauté), `consent`, `consent_event`, `community_live_settings` ; `device_owner_window` lu pour les jours détenus (`held`), pas copié | `rollup_device_*`, `rollup_community_hour`, `rollup_operation_hour` (le jour suffit ; par appareil = une courbe individuelle), `ingest_dead_letter`, `rollup_dirty`, `enrollment_token`, `device_last`, `forecast_*` |

Services sans données, jamais interrogés : `document-generation`,
`notification-dispatch`, `dso-lookup`.

## 7. Contenu par périmètre

« API » renvoie à la lecture existante dont le handler réutilise les fonctions.

### `crm`

| Fichier | Utilisateur (API `/me`, `/users`) | Communauté (API communauté, ADMIN) |
| --- | --- | --- |
| `identity.json` | Keycloak : profil, attributs, fournisseurs d'identité liés, rôles et groupes, date de création. Jamais de hash, de secret, d'OTP ni de credential | — |
| `account.json` | `app_user` (coordonnées, NRN, IBAN, adresses, langue), préférences de notification, onboarding, communautés et rôle | — |
| `community.json` | — | identité, données légales et bancaires, représentant, contact public (e-mail, téléphone), régulateur, modules activés, logo (référence) |
| `users.json` | — | comptes de la communauté : nom, e-mail, rôle |
| `members.json` | membres liés à lui (personne physique ou morale, gestionnaire, adresses, statut) | tous les membres que l'écran membres montre |
| `meters.json` | compteurs de ses membres, historique `meter_data` limité aux périodes de ses membres | tous les compteurs, historique complet |
| `consumptions/<EAN>/<AAAA>.csv` | consommations de ses compteurs, sur les périodes de ses membres | consommations de tous les compteurs |
| `sharing-participations.json` | participations de ses membres (EAN, opération, période) | — |
| `sharing-operations.json` | — | toutes les opérations, communes (codes INS), clés appliquées |
| `sharing-operation-consumptions/<opId>/<AAAA>.csv` | — | consommations par opération |
| `allocation-shares.json` | **uniquement la part de ses membres**, dans la clé en vigueur au jour de l'export (`/me/allocation-shares`) | — |
| `allocation-keys.json` | — | toutes les clés, itérations et consommateurs |
| `documents.json` + `documents/files/…` | documents de ses membres | tous les documents de la communauté |
| `invitations.json` | invitations reçues | invitations en attente (membres et gestionnaires) |
| `notifications.json` | notifications reçues | — (jamais de notification individuelle) |
| `email-messages.json` | e-mails mis en file pour lui : type, canal, statut, dates (jamais le contenu) | — |
| `email-suppression.json` | blocage de son adresse, s'il existe | — |
| `regulatory-status.json` | — | tous les épisodes réglementaires, module actif ou non |
| `activity-log.json` | ses actions, actions d'admin comprises, toutes communautés et hors communauté | journal d'activité de la communauté |

Les CSV ont l'en-tête `timestamp_utc,gross_kwh,net_kwh,shared_kwh,inj_gross_kwh,inj_shared_kwh,inj_net_kwh`
(valeurs telles qu'enregistrées, vide = absent). Un document dont l'objet manque dans le
stockage reste listé dans `documents.json` avec `file_missing: true` et le compteur
`export.crm.documents_missing`, au lieu de faire échouer tous les exports de la communauté.
Les fichiers JSON sont décrits par `schemas/files/crm/<fichier>.schema.json` (stricts : un
champ ajouté passe par une nouvelle version mineure et ses schémas).

### `signature`

| Fichier | Utilisateur (`/me/requests`, sans le contrôle de module) | Communauté (ADMIN) |
| --- | --- | --- |
| `requests.json` | les demandes où lui, ou un membre lié à lui, a un créneau ; **seulement ses créneaux** et leurs champs ; `chain` nul | toutes les demandes (`/admin/requests`), tous les créneaux et champs, les révisions, le contrôle de la chaîne de preuve (`chain`) |
| `events.json` | les lignes de ses créneaux et celles de la demande elle-même ; pour l'action de quelqu'un d'autre, qui, réseau et session sont nuls (`identity_withheld`) | toute la piste d'audit, ligne pour ligne telle que la chaîne la hache : les empreintes se recalculent depuis l'archive (dates au format de la chaîne, `%Y-%m-%dT%H:%M:%S.%fZ`) |
| `files/<requestId>/signed.pdf`, `evidence.pdf`, `evidence.json` | ceux de ses demandes terminées, comme l'app les lui donne | ceux de toutes les demandes terminées |

Les fichiers sont des `references` au bucket `optimce-documents`. Un fichier dont l'objet manque
reste décrit dans `requests.json` (`file_missing: true`, compteur `export.signature.files_missing`).
L'image de signature dessinée n'est pas exportée à part : elle est dans le PDF signé.

### `administrative-document`

| Fichier | Utilisateur | Communauté (ADMIN) |
| --- | --- | --- |
| `filings.json` | `/filings/mine` lui-même, dans chaque communauté où un membre lui est lié : la démarche et, du snapshot figé, **ses seules lignes** (décision B4) | — |
| `member-pieces.json` | les pièces adressées à un de ses membres (`document.id_member`, une annexe 8…), avec le fichier de la version courante si elle est FINALE | — |
| `procedures.json`, `documents.json`, `document-versions.json`, `version-checks.json`, `journal.json`, `deadlines.json`, `changes.json`, `correspondence.json`, `inbound-addresses.json`, `inbound-mails.json`, `inbound-mail-attachments.json`, `digest-settings.json`, `piece-signatures.json` | — | chaque table de §6, ligne pour ligne, sans `id_community` (le périmètre) ; les codes par leur nom (un code retiré garde son numéro) ; `procedures` gagne `procedure_code`/`procedure_version` |
| `files/versions/…`, `files/correspondence/…`, `files/inbound-mails/…` | le fichier de ses pièces FINALES | tous les fichiers stockés |

Un formulaire de communauté n'entre jamais dans un export utilisateur : son fichier nomme tous les
membres (seules ses lignes du snapshot y sont). Les schémas des tables sont dérivés du code
(`api/data_export.TABLES` et les types SQLAlchemy). Un fichier introuvable, ou dans un bucket que
le worker ne lit pas, reste décrit avec `file_missing: true`.

### `billing`

| Fichier | Utilisateur | Communauté (ADMIN) |
| --- | --- | --- |
| `my-invoices.json` | `/invoices/mine` lui-même, toutes les pages, dans chaque communauté où un membre lui est lié : chaque document (factures, notes de crédit, décomptes producteur) comme `GET /invoices/{id}` le montre, avec ses lignes, ses paiements (`GET /invoices/{id}/payments`) et son PDF | — |
| `tariffs.json`, `billing-runs.json`, `settlement-snapshots.json`, `invoices.json`, `invoice-lines.json`, `credit-notes.json`, `payments.json` | — | chaque table de §6, ligne pour ligne, sans `id_community` ; codes par leur nom ; montants et quantités en texte décimal tel que stocké |
| `files/invoices/<id>-<numéro>.pdf` | le PDF de ses documents, comme `GET /invoices/{id}/pdf` le donne à son titulaire | tous les PDF |

Un PDF hors du bucket des documents, ou introuvable, reste décrit avec `file_missing: true`.

### `news-board`

| Fichier | Utilisateur | Communauté (ADMIN) |
| --- | --- | --- |
| `my-posts.json` | les actualités et sondages qu'il a publiés (toutes communautés), avec leurs options | — |
| `my-votes.json` | chaque option pour laquelle il a voté, avec son sondage | — |
| `posts.json` | — | toutes les actualités et tous les sondages, chaque option avec son nombre de votes et le nombre de votants ; **jamais qui a voté quoi** (un vote est la donnée du membre, dans son export) |

Pas de fichier : une actualité est du Markdown en base. news-board n'utilise NATS que pour
l'export ; il s'y connecte en arrière-plan, une panne du broker n'empêche jamais l'API de démarrer.

### `simulation-key`

| Fichier | Utilisateur | Communauté (ADMIN) |
| --- | --- | --- |
| — | rien : une simulation appartient à sa communauté (`files: []`) | — |
| `simulations.json`, `key-results.json`, `iteration-results.json`, `consumer-results.json` | — | chaque table de §6, ligne pour ligne, sans `id_community` ; codes par leur nom ; un résultat NaN ou infini (que JSON ne sait pas écrire) vaut `null` |
| `files/<id>-input-<fichier>`, `files/<id>-timeseries.json` | — | le fichier de consommation simulé (source FILE) et la série par pas de temps de chaque simulation |

### `allocation-key-generation`

| Fichier | Utilisateur | Communauté (ADMIN) |
| --- | --- | --- |
| — | rien : une génération appartient à sa communauté (`files: []`) | — |
| `generations.json`, `generated-keys.json`, `generated-iterations.json`, `generated-consumers.json` | — | chaque table de §6, ligne pour ligne, sans `id_community` ; codes par leur nom ; un résultat NaN ou infini vaut `null` |
| `files/<id>-input-<fichier>` | — | le fichier de consommation de chaque génération (source FILE) |

Le module n'est pas vérifié : un export n'est pas un usage du module. Un fichier dont l'objet
manque reste décrit avec `file_missing: true` (compteur
`export.allocation-key-generation.files_missing`).

### `live-data`

| Fichier | Utilisateur | Communauté (ADMIN) |
| --- | --- | --- |
| `curves/<EAN>/<année>.csv` | la courbe complète de chaque compteur qu'un de ses membres a détenu, pour les jours détenus (fenêtres de propriété projetées depuis `meter_data`, jours de Bruxelles) : `interval_end` (FIN de l'intervalle, UTC), `interval_s`, `import_wh`, `export_wh`, `production_wh`, `device` ; une année de Bruxelles par fichier | — |
| `my-meters.json`, `my-consents.json` | chaque compteur (communauté, EAN), ses jours détenus, ses appareils et ses fichiers de courbe ; les décisions de consentement de ses membres | — |
| `days.json`, `operation-days.json` | — | les agrégats journaliers de la communauté et de chaque opération de partage, jugés comme dans l'app (`domain/kanon.py`, le k de la communauté) : la production toujours, les échanges réseau (import, export, partage estimé) seulement pour un jour qui passe k ; sinon `grid: withheld` et `omitted: below_threshold` dans le manifest |
| `devices.json`, `settings.json`, `consents.json` | — | les appareils, les réglages de visibilité (et le k appliqué), les décisions de consentement |

Jamais de courbe individuelle dans l'export communauté : ni `measurement`, ni rollup par appareil. Un jour qu'un autre détenteur couvre aussi (fenêtres qui se chevauchent, `ambiguous`) n'entre pas dans l'export utilisateur : la courbe peut être la sienne (compteur `periods_withheld`). Le consentement (`consent`) est inerte aujourd'hui : les agrégats suivent la règle de l'app (décision du 18/11/2026) ; le filtre « membres consentants » s'ajoutera quand le consentement existera. NATS est le seul usage du broker par live-data : le consumer se connecte en arrière-plan, l'API démarre sans lui.

### Annexes

| Service | Utilisateur | Communauté |
| --- | --- | --- |
| `signature` | demandes où lui ou un de ses membres signe (`/me/requests`), ses créneaux et leur piste d'audit, les PDF qu'il a reçus ou signés | toutes les demandes et pistes d'audit complètes (`/admin/requests`, `/requests/{id}/events`), PDF finaux et preuves |
| `administrative-document` | démarches qui concernent ses membres (`/filings/mine`), versions finales correspondantes | démarches, documents et versions, échéances, changements, correspondance, mails entrants et pièces jointes, réglages |
| `billing` | factures de ses membres (`/invoices/mine`) avec lignes, paiements, notes de crédit et PDF | tarifs, runs, instantanés de répartition, factures, notes de crédit, paiements, PDF |
| `news-board` | ses posts, ses votes | posts, sondages, résultats agrégés |
| `simulation-key` | rien (`files: []`) | simulations et résultats |
| `allocation-key-generation` | rien (`files: []`) | générations et clés générées |
| `live-data` | courbes complètes de ses compteurs (jours détenus), ses compteurs et ses consentements | agrégats journaliers sous le k de l'app ; aucune courbe individuelle |

## 8. Règles de confidentialité appliquées

- **Admin non membre** : son export personnel contient `identity`, `account` et
  `activity-log` (ses actions d'admin), rien d'autre de la communauté.
- **Clés de répartition** : l'export utilisateur ne contient que la part de ses
  propres membres (pourcentages, volumes alloués).
- **Documents multi-parties** : un document n'entre dans l'export utilisateur
  que s'il l'a signé ou reçu.
- **Membres personnes morales** : inclus tant que le lien de représentation est
  actif.
- **Notifications individuelles** : jamais dans l'export communauté.
- **Live data** : aucune courbe individuelle dans l'export communauté. Un agrégat
  sur moins de N contributeurs est omis et signalé (`omitted`, raison
  `below_threshold`).
- **Droits relus au traitement** : chaque handler revérifie le rôle du demandeur
  dans crm_db (`community_user.role`). S'il n'est plus ADMIN, la partie échoue
  en `forbidden`.
- **Module désactivé** : le service est quand même interrogé et exporte ce qu'il
  stocke. Le contrôle d'abonnement de l'API ne s'applique pas à l'export ; les
  contrôles de rôle et d'appartenance, si.

## 9. Écarts à la spec du 14/11

| Spec | Contrat | Raison |
| --- | --- | --- |
| Services `crm`, `documents`, `signature`, `notification`, `livedata` | `crm`, `signature`, `administrative-document`, `billing`, `news-board`, `simulation-key`, `allocation-key-generation`, `live-data` | Les documents membres et les notifications vivent dans crm-backend ; les autres données vivent dans leur annexe |
| Clés `<exportId>/parts/<service>/`, `<exportId>/optimce-export-…zip` | `parts/<exportId>/<service>/`, `archives/<exportId>/…` | ILM ne filtre que sur un préfixe de tête |
| `part.done` / `part.failed` sans `attempt` ni `schemaVersion` | les deux champs sont requis | La règle « attempt dépassé » en a besoin ; toutes les pièces du contrat sont versionnées |
| `scope.id`, `requester.userId` en UUID | identifiants Keycloak, chaîne | Ce sont les seuls identifiants communs à tous les services |
| `references[]` avec `size` et `sha256` | optionnels | Un service ne connaît pas toujours l'empreinte d'un objet existant ; le worker la calcule en le copiant |
| Un bucket de documents | `crm-files` et `optimce-documents` | Deux buckets existent |
| `reauth_required` | code d'erreur numérique crm-backend, HTTP 401 | Enveloppe d'erreur existante `{data, error_code}` |

## 10. Ajouter un service

Le contrat ne demande rien d'autre : **un service sans données répond une partie vide**
(`done`, `files: []`), et l'export de chacun reste complet. La checklist ci-dessous suit cet
ordre : d'abord une partie vide qui passe le contrat, ensuite le contenu.

### Checklist « nouveau service » (annexe Python)

1. **Le kit.** Copier `python/core/export/` vers `core/export/` et `python/tests/export_kit/`
   vers `tests/export_kit/`, tels quels (schémas compris). Ajouter `jsonschema==4.23.0` aux
   dépendances de l'API (et `nats-py`, `aiobotocore` si le service ne les a pas), et
   `jsonschema.*` aux `ignore_missing_imports` de mypy. Une image worker construite sur d'autres
   dépendances ne doit pas importer `core.export`.
2. **Une partie vide d'abord.** Brancher `empty_handler` : il répond `done` avec `files: []`.
   C'est le critère « service vide = contrat OK », prouvé par le test du kit
   `test_the_contract_check_passes_an_empty_handler` (dans `tests/export_kit/`, copié avec lui,
   donc lancé par la CI du service).
3. **Le consumer au boot.** Dans le lifespan, après la base : `run_export_consumer(js,
   service=..., handler=..., store=S3PartStore(ExportStorageSettings.from_env()), stop=...,
   expected_bucket=...)` en tâche de fond ; à l'arrêt, poser `stop` et attendre la tâche
   **avant** de fermer NATS. Sans `EXPORT_STORAGE_*`, ou sans NATS, le consumer est désactivé
   et journalisé : l'API démarre quand même. Modèle : `start_export_consumer` /
   `stop_export_consumer` de `billing/api/data_export.py`.
4. **Le contenu**, quand le service a des données à rendre. Le handler appelle d'abord
   `resolve_requester` (refus `forbidden`, `scope_not_found` ; le module désactivé ne cache
   rien), puis écrit la partie utilisateur et la partie communauté selon §7. Les tables vont
   ligne pour ligne, codes par leur nom, sans `id_community`. Les fichiers stockés vont en
   `references`, et un objet introuvable reste décrit avec `file_missing: true` et un compteur
   `files_missing`. Modèle : `TABLES` dans `simulation-key/api/data_export.py`.
5. **Les tests du service** (`tests/test_export.py`) : `run_contract_check` sur des périmètres de
   fixture — chaque table, un fichier manquant, un MANAGER refusé, une communauté inconnue,
   l'export utilisateur — et chaque fichier JSON validé contre son schéma. Ils tournent dans la
   CI du service : c'est le test de contrat, la CI du monorepo ne lançant aucun service.
6. **Schémas et libellés.** Décrire chaque fichier JSON dans `schemas/files/<service>/`, puis le
   recopier dans chaque arbre de schémas (cette référence, `crm-backend/assets/export/schemas/`,
   `python/core/export/schemas/` et le `core/export/schemas/` de chaque annexe : la parité
   compare des arbres entiers). Ajouter, dans les 4 langues de
   `crm-backend/assets/export/i18n/`, le nom du service (`services`) et chaque compteur
   `export.<service>.<nom>` (`labels`) ; sinon `index.html` affiche la clé.
7. **Le câblage.**
   - le compte MinIO : le service dans `EXPORT_SERVICE_ACCOUNTS` (`minio/export/provision.sh`)
     et son secret `EXPORT_<SERVICE>_SECRET` (`.env`, et l'environnement de `minio-init`) ;
   - `EXPORT_STORAGE_*` sur le service dans le compose, avec **son** compte
     `export-<service>`, jamais le compte de stockage habituel du service ;
   - le service dans `PY_ADOPTERS` (`scripts/check-export-parity.sh`) ;
   - §6 et §7 de ce document : tables exportées ou non, contenu par périmètre ;
   - le dépôt `production` : les mêmes comptes, variables et services.
8. **En dernier, `EXPORT_SERVICES`** (crm-backend : la liste des parties que chaque job
   demande). Seulement une fois le consumer du service déployé : avant, chaque export réel
   attend sa partie, puis échoue après les relances (3 × 30 min).
9. **Vérifier** : `./scripts/check-export-parity.sh` (les copies sont identiques), puis, sur le
   stack dev redéployé, `./scripts/verify-export-contract.sh` (chaque service répond).

### Vérifier le stack : `scripts/verify-export-contract.sh`

Ce que la CI d'aucun service ne voit : les services déployés ensemble, sur le vrai broker et le
vrai bucket, répondent-ils à un vrai job ?

```
./scripts/verify-export-contract.sh [--timeout 60] [--scope user|community|both]
                                    [--services a,b,...] [--keep]
```

- Il crée dans crm_db un demandeur et une communauté jetables
  (`export-contract-probe-<run>`, le demandeur ADMIN, rien d'autre dedans), puis injecte un
  export utilisateur et un export communauté comme le ferait l'API : un `export_job` et une
  `export_part` par service d'`EXPORT_SERVICES`, puis `export.job.requested`. Si la
  publication échoue, le sweep du worker démarre les jobs à son tick suivant.
- Il attend chaque partie et **échoue en nommant le service** quand une partie n'est pas `done`
  dans le délai de sa demande (60 s par défaut), ou répond `failed`. Une fois toutes les parties
  `done`, il attend l'archive.
- Il nettoie tout : parties et archives stockées, mails sortants, lignes de la sonde (jobs,
  parties et notifications suivent en cascade), mails Mailpit. Une sonde laissée par une
  exécution interrompue, ou par `--keep`, est supprimée au début de la suivante. Un service qui
  répond après le nettoyage ne trouve plus de job : le worker efface ce qu'il a écrit.
- Codes de sortie : `0` tout est `done` à temps et chaque archive est assemblée ; `1` un service
  a échoué, n'a pas répondu, ou l'archive n'a pas été assemblée ; `2` le stack n'est pas
  utilisable (un conteneur arrêté, aucun service).

Il prouve que chaque service répond, pas ce qu'il exporte : la sonde n'a aucune donnée. Le
contenu relève des tests de chaque service (étape 5).

C'est un outil du stack **dev** : il écrit dans crm_db en `postgres` et trouve les conteneurs
par leur nom compose (`COMPOSE_PROJECT_NAME`, ou `EXPORT_CHECK_PG`, `_API`, `_WORKER`,
`_NETWORK`).

Après un démarrage à froid de Docker Desktop, crm-backend et administrative-document peuvent
rester en vie sans servir. En dev, leur watcher (`tsx watch`, `uvicorn --reload`) survit à l'échec
de connexion à Postgres, et la politique de redémarrage n'agit pas. Le script les nomme
(`NO ANSWER`) : un `docker restart` de ces conteneurs suffit.

## 11. Critères d'acceptation → tests automatisés

Les 17 critères de la spec du 14/11, chacun relié aux tests qui le prouvent. Abréviations :

- **API**, **crm**, **worker** : les tests fonctionnels de crm-backend
  `tests/functionals/export/export-{api,crm,worker}.functional.test.ts` ;
- **kit Node** et **kit Python** : `export-kit.functional.test.ts`, et `tests/export_kit/`
  (copié dans chaque annexe) ;
- **e2e** : les scénarios Steppy `OptimCE/e2e/scenarios/data-export-*.md`.

| # | Critère | Tests | État |
| --- | --- | --- | --- |
| 1 | Un utilisateur obtient un ZIP avec son compte, ses membres, ses documents et un `manifest.json` valide contre son schéma | crm « holds the account, identity, members, meters, readings and documents, in valid files » ; worker « collects every part and assembles the archive » (l'assembleur valide `manifest.json` contre son schéma avant de l'écrire) ; e2e `data-export-user` (ZIP téléchargé depuis l'app : 7 parties `done`, chaque fichier vérifié en taille et SHA-256) | ✅ |
| 2 | Un admin non membre qui exporte ses données ne reçoit aucune donnée des membres | crm « gives an ADMIN who is no member their account and actions, nothing of the community's members » ; e2e `data-export-user` (`crm/members.json` vide) ; annexes : signature « someone with no slot gets empty files », administrative-document « someone linked to nobody gets empty files », billing « nobody else's bill and nothing for someone unlinked » | ✅ |
| 3 | Un document de communauté que l'utilisateur n'a ni signé ni reçu n'est pas dans son export | crm « leaves out a community document of a member who is not the user's » ; administrative-document « a draft or a form to sign is not handed over » ; signature « bob gets acme's slot, not alice's » | ✅ |
| 4 | Dans l'export utilisateur, seule la part de ses membres dans les clés de répartition apparaît | crm « shows only the share of the user's own members in an allocation key » | ✅ |
| 5 | L'export communauté ne contient aucune courbe individuelle de live data | live-data `tests/test_export.py` « daily aggregates judged as the app does and never a curve » (ni fichier `curves/`, ni mesure, ni rollup par appareil : `settings`, `devices`, `consents`, `days`, `operation-days` seulement) ; e2e `data-export-community` (aucun `live-data/curves/` dans le ZIP, `live-data/days.json` présent) | ✅ |
| 6 | Un agrégat calculé sur moins de N membres est omis et signalé dans le manifest | live-data « daily aggregates judged as the app does » (un jour à 2 membres : import, export et partage absents, `grid: withheld`, `omitted` `live-data.days.grid` et `live-data.operation-days.grid` en `below_threshold`) et « the community's own k is the threshold » (k de la communauté, minimum 3, comme l'app : `domain/kanon.py`) ; N est le k de l'app (5 par défaut) | ✅ |
| 7 | L'export communauté ne contient aucune notification individuelle | crm « holds the community, its users, members, … never a notification » ; e2e `data-export-community` (ni `notifications.json`, ni `email-messages.json`, ni `identity.json`, ni `account.json`) | ✅ |
| 8 | Une demande sans authentification récente renvoie `reauth_required` | API « answers 401 reauth_required without a recent login, and creates nothing » ; front `data-export-panel.spec.ts` « keeps the request and logs in again with max_age=300 », « replays the kept request once on return » | ✅ |
| 9 | Un autre utilisateur, y compris un autre admin, ne peut pas obtenir d'URL de téléchargement | API « refuses another ADMIN of the community (403) and anyone else (404) » ; e2e `data-export-community` (le second admin n'a pas de bouton, l'API lui répond 403 `35005`) | ✅ |
| 10 | Une deuxième demande pendant un export actif renvoie `409` | API « answers 409 while an export of the same scope is in progress », « serialises two requests at once: one export, one 409 » ; e2e `data-export-conflict` (bouton désactivé, l'API répond 409 `35002`) | ✅ |
| 11 | Un export expiré ne peut plus être téléchargé et son objet n'existe plus dans MinIO | worker « expires a ready export: archive deleted, row kept, audited » ; API « answers 410 once the archive expired » | ✅ |
| 12 | Si un service échoue définitivement, le job passe en `failed` et aucun ZIP n'est livré | worker « fails the whole export when one service fails for good: no archive, parts deleted, requester told, audited », « asks again a service that does not answer, then fails the part after the last attempt » | ✅ |
| 13 | Un message livré deux fois ne produit ni doublon ni fichier corrompu | worker « starts a job announced twice once, and assembles a part answered twice once » ; kit Node « delivered twice, writes once and gives the same answer twice » ; kit Python « delivered twice it writes once » | ✅ |
| 14 | Après un redémarrage du worker en pleine collecte, l'export se termine | worker « finishes an export after the worker restarted in the middle of the collection », « takes over an assembly a dead worker left behind » ; kits « a shutdown naks and the next instance finishes » | ✅ |
| 15 | Le test de contrat échoue si un service de `EXPORT_SERVICES` ne répond pas | `scripts/verify-export-contract.sh` (§10 ; il nomme le service, vérifié avec news-board arrêté) ; kit Python « the contract check fails a handler that never answers » | ✅ sur le stack dev (la CI du monorepo ne lance aucun service) |
| 16 | La mémoire du worker reste stable pendant l'assemblage d'un export volumineux | crm-backend `tests/units/exports/export-assembler-memory.test.ts` « keeps the same, small amount of memory however large the export » : le vrai assembleur et le vrai upload multipart (lib-storage, S3 répondu dans le process) sur des exports synthétiques de 64 et 512 Mio ; la mémoire encore atteignable après un GC forcé à chaque part reste sous 64 Mio, sans grandir avec la taille (mesuré : +18 à +25 Mio pour les deux). Une source ou une archive gardée entière le fait échouer (+371 et +331 Mio, vérifié par mutation) | ✅ |
| 17 | Un service généré depuis le template Python passe le test de contrat sans modification, en renvoyant une partie vide | pas de template (décision du 15/11) : le kit fournit `empty_handler`, prouvé par « the contract check passes an empty handler » (dans `tests/export_kit/`, donc dans la CI de chaque annexe) ; checklist §10 | ✅ (adapté) |

Les scénarios e2e réinitialisent crm_db (seed `crm_data_seed`) et recréent demo2 dans Keycloak :
prendre un snapshot avant, le restaurer après. Passés le 18/11/2026 : 3/3, deux fois de suite.
