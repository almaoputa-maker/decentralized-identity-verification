;; Decentralized Identity Verification Smart Contract
;; title: identity-registry
;; version: 1.0.0
;; summary: DID registry, credential issuance, and revocation management
;; description: A comprehensive smart contract for managing decentralized identities,
;;              issuing verifiable credentials, and handling revocation on Stacks blockchain

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-did (err u104))
(define-constant err-credential-revoked (err u105))
(define-constant err-credential-expired (err u106))
(define-constant err-invalid-issuer (err u107))
(define-constant err-invalid-signature (err u108))

;; Data Variables
(define-data-var next-did-id uint u0)
(define-data-var next-credential-id uint u0)
(define-data-var contract-paused bool false)
(define-data-var total-dids uint u0)
(define-data-var total-credentials uint u0)

;; Data Maps

;; DID Registry - Maps DID string to DID data
(define-map dids
  { did: (string-ascii 64) }
  {
    owner: principal,
    metadata-hash: (string-ascii 64),
    created-at: uint,
    updated-at: uint,
    active: bool,
    did-id: uint
  }
)

;; DID by Principal - Maps principal to their DID
(define-map principal-to-did
  { owner: principal }
  { did: (string-ascii 64) }
)

;; Credentials Registry
(define-map credentials
  { credential-id: (string-ascii 64) }
  {
    issuer: principal,
    subject: principal,
    credential-hash: (string-ascii 64),
    issued-at: uint,
    expires-at: uint,
    active: bool,
    credential-type: (string-ascii 32),
    revoked: bool,
    revoked-at: (optional uint)
  }
)

;; Trusted Issuers Registry
(define-map trusted-issuers
  { issuer: principal }
  {
    registered-at: uint,
    active: bool,
    reputation-score: uint,
    total-issued: uint
  }
)

;; Revocation Registry
(define-map revoked-credentials
  { credential-id: (string-ascii 64) }
  {
    revoked-by: principal,
    revoked-at: uint,
    reason: (string-ascii 128)
  }
)

;; Credential schemas
(define-map credential-schemas
  { schema-id: (string-ascii 32) }
  {
    schema-hash: (string-ascii 64),
    created-by: principal,
    active: bool
  }
)

;; Public Functions

;; Create a new DID
(define-public (create-did (did (string-ascii 64)) (metadata-hash (string-ascii 64)))
  (let ((current-did-id (var-get next-did-id)))
    (asserts! (not (var-get contract-paused)) (err u999))
    (asserts! (is-none (map-get? dids { did: did })) err-already-exists)
    (asserts! (> (len did) u0) err-invalid-did)
    
    (map-set dids
      { did: did }
      {
        owner: tx-sender,
        metadata-hash: metadata-hash,
        created-at: block-height,
        updated-at: block-height,
        active: true,
        did-id: current-did-id
      }
    )
    
    (map-set principal-to-did
      { owner: tx-sender }
      { did: did }
    )
    
    (var-set next-did-id (+ current-did-id u1))
    (var-set total-dids (+ (var-get total-dids) u1))
    
    (print { event: "did-created", did: did, owner: tx-sender, did-id: current-did-id })
    (ok current-did-id)
  )
)

;; Update DID metadata
(define-public (update-did-metadata (did (string-ascii 64)) (new-metadata-hash (string-ascii 64)))
  (let ((did-data (unwrap! (map-get? dids { did: did }) err-not-found)))
    (asserts! (is-eq tx-sender (get owner did-data)) err-unauthorized)
    (asserts! (get active did-data) err-not-found)
    
    (map-set dids
      { did: did }
      (merge did-data {
        metadata-hash: new-metadata-hash,
        updated-at: block-height
      })
    )
    
    (print { event: "did-updated", did: did, metadata-hash: new-metadata-hash })
    (ok true)
  )
)

;; Issue a credential
(define-public (issue-credential 
    (credential-id (string-ascii 64))
    (subject principal)
    (credential-hash (string-ascii 64))
    (expires-at uint)
    (credential-type (string-ascii 32)))
  (begin
    (asserts! (not (var-get contract-paused)) (err u999))
    (asserts! (is-some (map-get? trusted-issuers { issuer: tx-sender })) err-invalid-issuer)
    (asserts! (is-none (map-get? credentials { credential-id: credential-id })) err-already-exists)
    (asserts! (> expires-at block-height) err-credential-expired)
    
    (map-set credentials
      { credential-id: credential-id }
      {
        issuer: tx-sender,
        subject: subject,
        credential-hash: credential-hash,
        issued-at: block-height,
        expires-at: expires-at,
        active: true,
        credential-type: credential-type,
        revoked: false,
        revoked-at: none
      }
    )
    
    ;; Update issuer stats
    (map-set trusted-issuers
      { issuer: tx-sender }
      (merge (unwrap-panic (map-get? trusted-issuers { issuer: tx-sender })) {
        total-issued: (+ (get total-issued (unwrap-panic (map-get? trusted-issuers { issuer: tx-sender }))) u1)
      })
    )
    
    (var-set next-credential-id (+ (var-get next-credential-id) u1))
    (var-set total-credentials (+ (var-get total-credentials) u1))
    
    (print { event: "credential-issued", credential-id: credential-id, issuer: tx-sender, subject: subject })
    (ok true)
  )
)

;; Revoke a credential
(define-public (revoke-credential (credential-id (string-ascii 64)) (reason (string-ascii 128)))
  (let ((credential (unwrap! (map-get? credentials { credential-id: credential-id }) err-not-found)))
    (asserts! (or (is-eq tx-sender (get issuer credential)) (is-eq tx-sender (get subject credential))) err-unauthorized)
    (asserts! (not (get revoked credential)) err-credential-revoked)
    
    (map-set credentials
      { credential-id: credential-id }
      (merge credential {
        revoked: true,
        revoked-at: (some block-height),
        active: false
      })
    )
    
    (map-set revoked-credentials
      { credential-id: credential-id }
      {
        revoked-by: tx-sender,
        revoked-at: block-height,
        reason: reason
      }
    )
    
    (print { event: "credential-revoked", credential-id: credential-id, revoked-by: tx-sender })
    (ok true)
  )
)

;; Register as trusted issuer (only contract owner)
(define-public (register-trusted-issuer (issuer principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-none (map-get? trusted-issuers { issuer: issuer })) err-already-exists)
    
    (map-set trusted-issuers
      { issuer: issuer }
      {
        registered-at: block-height,
        active: true,
        reputation-score: u100,
        total-issued: u0
      }
    )
    
    (print { event: "trusted-issuer-registered", issuer: issuer })
    (ok true)
  )
)

;; Read-only functions

;; Get DID information
(define-read-only (get-did (did (string-ascii 64)))
  (map-get? dids { did: did })
)

;; Get DID by principal
(define-read-only (get-did-by-principal (owner principal))
  (map-get? principal-to-did { owner: owner })
)

;; Verify credential
(define-read-only (verify-credential (credential-id (string-ascii 64)))
  (match (map-get? credentials { credential-id: credential-id })
    credential
      (if (and (get active credential) 
               (not (get revoked credential))
               (> (get expires-at credential) block-height))
        (ok {
          valid: true,
          reason: "valid",
          issuer: (some (get issuer credential)),
          subject: (some (get subject credential)),
          issued-at: (some (get issued-at credential)),
          expires-at: (some (get expires-at credential))
        })
        (ok { 
          valid: false, 
          reason: "invalid-or-expired",
          issuer: none,
          subject: none,
          issued-at: none,
          expires-at: none
        })
      )
    (ok { 
      valid: false, 
      reason: "not-found",
      issuer: none,
      subject: none,
      issued-at: none,
      expires-at: none
    })
  )
)

;; Get credential details
(define-read-only (get-credential (credential-id (string-ascii 64)))
  (map-get? credentials { credential-id: credential-id })
)

;; Check if issuer is trusted
(define-read-only (is-trusted-issuer (issuer principal))
  (match (map-get? trusted-issuers { issuer: issuer })
    issuer-data (get active issuer-data)
    false
  )
)

;; Get revocation details
(define-read-only (get-revocation-info (credential-id (string-ascii 64)))
  (map-get? revoked-credentials { credential-id: credential-id })
)

;; Get contract statistics
(define-read-only (get-stats)
  {
    total-dids: (var-get total-dids),
    total-credentials: (var-get total-credentials),
    next-did-id: (var-get next-did-id),
    next-credential-id: (var-get next-credential-id),
    contract-paused: (var-get contract-paused)
  }
)

;; Admin functions

;; Pause/unpause contract (only owner)
(define-public (toggle-contract-pause)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set contract-paused (not (var-get contract-paused)))
    (print { event: "contract-pause-toggled", paused: (var-get contract-paused) })
    (ok (var-get contract-paused))
  )
)

;; Emergency revoke credential (only owner)
(define-public (emergency-revoke-credential (credential-id (string-ascii 64)) (reason (string-ascii 128)))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (revoke-credential credential-id reason)
  )
)
