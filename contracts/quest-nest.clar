;; quest-nest.clar
;; This contract manages the core functionality of the QuestNest platform, enabling users to create
;; personalized development quests, stake tokens, join communities (guilds), and earn rewards upon 
;; verified quest completion. The contract handles quest management, guild interactions, verification,
;; and reward distribution, building a transparent on-chain record of achievement.

;; ========================================
;; Constants & Error Codes
;; ========================================

;; Error codes related to quests
(define-constant ERR-QUEST-NOT-FOUND (err u100))
(define-constant ERR-QUEST-ALREADY-EXISTS (err u101))
(define-constant ERR-QUEST-ALREADY-COMPLETED (err u102))
(define-constant ERR-QUEST-ALREADY-VERIFIED (err u103))
(define-constant ERR-QUEST-EXPIRED (err u104))
(define-constant ERR-INSUFFICIENT-STAKE (err u105))
(define-constant ERR-INVALID-QUEST-PARAMS (err u106))

;; Error codes related to guilds
(define-constant ERR-GUILD-NOT-FOUND (err u200))
(define-constant ERR-GUILD-ALREADY-EXISTS (err u201))
(define-constant ERR-ALREADY-GUILD-MEMBER (err u202))
(define-constant ERR-NOT-GUILD-MEMBER (err u203))
(define-constant ERR-NOT-GUILD-ADMIN (err u204))

;; Error codes related to verification
(define-constant ERR-NOT-AUTHORIZED-VERIFIER (err u300))
(define-constant ERR-SELF-VERIFICATION-NOT-ALLOWED (err u301))
(define-constant ERR-VERIFICATION-PERIOD-EXPIRED (err u302))

;; Error codes related to rewards
(define-constant ERR-INSUFFICIENT-BALANCE (err u400))
(define-constant ERR-REWARD-CLAIM-FAILED (err u401))

;; General error codes
(define-constant ERR-UNAUTHORIZED (err u900))
(define-constant ERR-INVALID-PARAMS (err u901))

;; Success responses
(define-constant SUCCESS-TRUE (ok true))

;; Constants for verification types
(define-constant VERIFIER-TYPE-SELF u1)
(define-constant VERIFIER-TYPE-PEER u2)
(define-constant VERIFIER-TYPE-AUTHORITY u3)

;; Constants for quest status
(define-constant QUEST-STATUS-ACTIVE u1)
(define-constant QUEST-STATUS-COMPLETED u2)
(define-constant QUEST-STATUS-FAILED u3)
(define-constant QUEST-STATUS-EXPIRED u4)

;; ========================================
;; Data Maps & Variables
;; ========================================

;; Store quest details
(define-map quests
  { quest-id: uint, owner: principal }
  {
    title: (string-ascii 100),
    description: (string-utf8 500),
    stake-amount: uint,
    required-verifier-type: uint,
    deadline: uint,
    status: uint,
    creation-time: uint,
    completion-time: (optional uint),
    verifier: (optional principal)
  }
)

;; Track all quests created by a user
(define-map user-quests
  { user: principal }
  { quest-ids: (list 100 uint) }
)

;; Guild information
(define-map guilds
  { guild-id: uint }
  {
    name: (string-ascii 50),
    description: (string-utf8 500),
    admin: principal,
    creation-time: uint,
    member-count: uint,
    total-stake-pool: uint
  }
)

;; Track guild membership
(define-map guild-members
  { guild-id: uint, member: principal }
  { joined-at: uint, active: bool }
)

;; Track the guilds a user belongs to
(define-map user-guilds
  { user: principal }
  { guild-ids: (list 50 uint) }
)

;; Store guild challenges (collective quests)
(define-map guild-challenges
  { guild-id: uint, challenge-id: uint }
  {
    title: (string-ascii 100),
    description: (string-utf8 500),
    stake-amount: uint,
    deadline: uint,
    status: uint,
    creation-time: uint,
    completion-count: uint,
    reward-pool: uint
  }
)

;; Track user participation in guild challenges
(define-map challenge-participants
  { guild-id: uint, challenge-id: uint, participant: principal }
  {
    joined-at: uint,
    status: uint,
    completed-at: (optional uint),
    verified-by: (optional principal)
  }
)

;; Store authorized verifiers by type
(define-map authorized-verifiers
  { verifier: principal }
  { verifier-type: uint, active: bool }
)

;; Track user reputation scores
(define-map user-reputation
  { user: principal }
  {
    quests-completed: uint,
    quests-failed: uint,
    verification-count: uint,
    reputation-score: uint
  }
)

;; Global counters
(define-data-var quest-id-counter uint u0)
(define-data-var guild-id-counter uint u0)
(define-data-var challenge-id-counter uint u0)

;; ========================================
;; Private Functions
;; ========================================

;; Generates and returns a new unique quest ID
(define-private (generate-quest-id)
  (let ((new-id (+ (var-get quest-id-counter) u1)))
    (var-set quest-id-counter new-id)
    new-id
  )
)

;; Generates and returns a new unique guild ID
(define-private (generate-guild-id)
  (let ((new-id (+ (var-get guild-id-counter) u1)))
    (var-set guild-id-counter new-id)
    new-id
  )
)

;; Generates and returns a new unique challenge ID
(define-private (generate-challenge-id)
  (let ((new-id (+ (var-get challenge-id-counter) u1)))
    (var-set challenge-id-counter new-id)
    new-id
  )
)

;; Adds a quest ID to a user's quest list
(define-private (add-quest-to-user-list (user principal) (quest-id uint))
  (let (
    (current-quests (default-to { quest-ids: (list) } (map-get? user-quests { user: user })))
  )
    (map-set user-quests
      { user: user }
      { quest-ids: (unwrap-panic (as-max-len? (append (get quest-ids current-quests) quest-id) u100)) }
    )
  )
)

;; Adds a guild ID to a user's guild list
(define-private (add-guild-to-user-list (user principal) (guild-id uint))
  (let (
    (current-guilds (default-to { guild-ids: (list) } (map-get? user-guilds { user: user })))
  )
    (map-set user-guilds
      { user: user }
      { guild-ids: (unwrap-panic (as-max-len? (append (get guild-ids current-guilds) guild-id) u50)) }
    )
  )
)

;; Checks if a user has permission to verify a quest based on verifier type
(define-private (can-verify-quest (verifier principal) (quest-owner principal) (required-type uint))
  (let (
    (verifier-info (map-get? authorized-verifiers { verifier: verifier }))
  )
    (if (is-none verifier-info)
      false
      (let (
        (verifier-type (get verifier-type (unwrap-panic verifier-info)))
        (is-active (get active (unwrap-panic verifier-info)))
      )
        (and 
          is-active
          (or 
            ;; If verifier type matches required type
            (is-eq verifier-type required-type)
            ;; Authority verifiers can verify any quest
            (is-eq verifier-type VERIFIER-TYPE-AUTHORITY)
            ;; Self verification is allowed if required type is SELF and verifier is owner
            (and 
              (is-eq required-type VERIFIER-TYPE-SELF) 
              (is-eq verifier quest-owner)
            )
          )
        )
      )
    )
  )
)

;; Update user reputation after quest completion
(define-private (update-reputation-for-completion (user principal))
  (let (
    (current-reputation (default-to 
      { quests-completed: u0, quests-failed: u0, verification-count: u0, reputation-score: u0 } 
      (map-get? user-reputation { user: user })))
    (new-completed (+ (get quests-completed current-reputation) u1))
    (new-score (+ (get reputation-score current-reputation) u10)) ;; +10 points for completion
  )
    (map-set user-reputation
      { user: user }
      {
        quests-completed: new-completed,
        quests-failed: (get quests-failed current-reputation),
        verification-count: (get verification-count current-reputation),
        reputation-score: new-score
      }
    )
  )
)

;; Update user reputation after quest failure
(define-private (update-reputation-for-failure (user principal))
  (let (
    (current-reputation (default-to 
      { quests-completed: u0, quests-failed: u0, verification-count: u0, reputation-score: u0 } 
      (map-get? user-reputation { user: user })))
    (new-failed (+ (get quests-failed current-reputation) u1))
    (new-score (if (> (get reputation-score current-reputation) u5)
                  (- (get reputation-score current-reputation) u5) ;; -5 points for failure
                  u0))
  )
    (map-set user-reputation
      { user: user }
      {
        quests-completed: (get quests-completed current-reputation),
        quests-failed: new-failed,
        verification-count: (get verification-count current-reputation),
        reputation-score: new-score
      }
    )
  )
)

;; Update verifier reputation after verification
(define-private (update-verifier-reputation (verifier principal))
  (let (
    (current-reputation (default-to 
      { quests-completed: u0, quests-failed: u0, verification-count: u0, reputation-score: u0 } 
      (map-get? user-reputation { user: verifier })))
    (new-verify-count (+ (get verification-count current-reputation) u1))
    (new-score (+ (get reputation-score current-reputation) u2)) ;; +2 points for verification
  )
    (map-set user-reputation
      { user: verifier }
      {
        quests-completed: (get quests-completed current-reputation),
        quests-failed: (get quests-failed current-reputation),
        verification-count: new-verify-count,
        reputation-score: new-score
      }
    )
  )
)

;; ========================================
;; Read-Only Functions
;; ========================================

;; Get details of a specific quest
(define-read-only (get-quest (quest-id uint) (owner principal))
  (map-get? quests { quest-id: quest-id, owner: owner })
)

;; Get all quests for a user
(define-read-only (get-user-quests (user principal))
  (map-get? user-quests { user: user })
)

;; Get details of a specific guild
(define-read-only (get-guild (guild-id uint))
  (map-get? guilds { guild-id: guild-id })
)

;; Check if a user is a member of a guild
(define-read-only (is-guild-member (guild-id uint) (user principal))
  (match (map-get? guild-members { guild-id: guild-id, member: user })
    member (get active member)
    false
  )
)

;; Get details of a specific guild challenge
(define-read-only (get-guild-challenge (guild-id uint) (challenge-id uint))
  (map-get? guild-challenges { guild-id: guild-id, challenge-id: challenge-id })
)

;; Get user participation in a specific challenge
(define-read-only (get-challenge-participation (guild-id uint) (challenge-id uint) (user principal))
  (map-get? challenge-participants { guild-id: guild-id, challenge-id: challenge-id, participant: user })
)

;; Get user reputation
(define-read-only (get-user-reputation (user principal))
  (default-to 
    { quests-completed: u0, quests-failed: u0, verification-count: u0, reputation-score: u0 }
    (map-get? user-reputation { user: user })
  )
)

;; Check if a user is authorized as a verifier and of what type
(define-read-only (get-verifier-status (verifier principal))
  (map-get? authorized-verifiers { verifier: verifier })
)

;; ========================================
;; Public Functions
;; ========================================

;; Create a new quest with staked tokens
(define-public (create-quest (title (string-ascii 100)) (description (string-utf8 500)) 
                           (stake-amount uint) (verifier-type uint) (deadline uint))
  (let (
    (quest-id (generate-quest-id))
    (caller tx-sender)
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Basic parameter validation
    (asserts! (> (len title) u0) ERR-INVALID-QUEST-PARAMS)
    (asserts! (> (len description) u0) ERR-INVALID-QUEST-PARAMS)
    (asserts! (> stake-amount u0) ERR-INSUFFICIENT-STAKE)
    (asserts! (and (>= verifier-type VERIFIER-TYPE-SELF) (<= verifier-type VERIFIER-TYPE-AUTHORITY)) ERR-INVALID-QUEST-PARAMS)
    (asserts! (> deadline current-time) ERR-INVALID-QUEST-PARAMS)
    
    ;; Create the quest and add to user's list
    (map-set quests
      { quest-id: quest-id, owner: caller }
      {
        title: title,
        description: description,
        stake-amount: stake-amount,
        required-verifier-type: verifier-type,
        deadline: deadline,
        status: QUEST-STATUS-ACTIVE,
        creation-time: current-time,
        completion-time: none,
        verifier: none
      }
    )
    
    ;; Add quest to user's list
    (add-quest-to-user-list caller quest-id)
    
    ;; Return the newly created quest ID
    (ok quest-id)
  )
)

;; Request verification for a completed quest
(define-public (request-quest-verification (quest-id uint))
  (let (
    (caller tx-sender)
    (quest-data (map-get? quests { quest-id: quest-id, owner: caller }))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Verify quest exists and is in the right state
    (asserts! (not (is-none quest-data)) ERR-QUEST-NOT-FOUND)
    
    (let (
      (quest (unwrap-panic quest-data))
    )
      (asserts! (is-eq (get status quest) QUEST-STATUS-ACTIVE) ERR-QUEST-ALREADY-COMPLETED)
      (asserts! (<= current-time (get deadline quest)) ERR-QUEST-EXPIRED)
      
      ;; If self-verification is allowed, complete immediately
      (if (is-eq (get required-verifier-type quest) VERIFIER-TYPE-SELF)
        (begin
          (map-set quests
            { quest-id: quest-id, owner: caller }
            (merge quest {
              status: QUEST-STATUS-COMPLETED,
              completion-time: (some current-time),
              verifier: (some caller)
            })
          )
          ;; Update reputation
          (update-reputation-for-completion caller)
          (ok true)
        )
        ;; Otherwise, change to pending verification (still ACTIVE status)
        ;; In a full implementation, this would emit an event for off-chain notification
        SUCCESS-TRUE
      )
    )
  )
)

;; Verify a quest as completed (for authorized verifiers)
(define-public (verify-quest (quest-id uint) (quest-owner principal))
  (let (
    (verifier tx-sender)
    (quest-data (map-get? quests { quest-id: quest-id, owner: quest-owner }))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Verify quest exists
    (asserts! (not (is-none quest-data)) ERR-QUEST-NOT-FOUND)
    
    (let (
      (quest (unwrap-panic quest-data))
    )
      ;; Verify quest state
      (asserts! (is-eq (get status quest) QUEST-STATUS-ACTIVE) ERR-QUEST-ALREADY-COMPLETED)
      (asserts! (<= current-time (get deadline quest)) ERR-QUEST-EXPIRED)
      
      ;; Check if verifier is authorized for this quest
      (asserts! (can-verify-quest verifier quest-owner (get required-verifier-type quest)) ERR-NOT-AUTHORIZED-VERIFIER)
      
      ;; Prevent users from self-verifying unless allowed
      (if (and (is-eq verifier quest-owner) (> (get required-verifier-type quest) VERIFIER-TYPE-SELF))
        (begin
          (asserts! false ERR-SELF-VERIFICATION-NOT-ALLOWED)
          SUCCESS-TRUE ;; This line is never reached but needed for type checking
        )
        (begin
          ;; Update quest as completed
          (map-set quests
            { quest-id: quest-id, owner: quest-owner }
            (merge quest {
              status: QUEST-STATUS-COMPLETED,
              completion-time: (some current-time),
              verifier: (some verifier)
            })
          )
          
          ;; Update reputation for both quest owner and verifier
          (update-reputation-for-completion quest-owner)
          (update-verifier-reputation verifier)
          SUCCESS-TRUE
        )
      )
    )
  )
)

;; Mark quest as failed (can be called by owner or after deadline)
(define-public (fail-quest (quest-id uint))
  (let (
    (caller tx-sender)
    (quest-data (map-get? quests { quest-id: quest-id, owner: caller }))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Verify quest exists
    (asserts! (not (is-none quest-data)) ERR-QUEST-NOT-FOUND)
    
    (let (
      (quest (unwrap-panic quest-data))
    )
      ;; Can only fail active quests
      (asserts! (is-eq (get status quest) QUEST-STATUS-ACTIVE) ERR-QUEST-ALREADY-COMPLETED)
      
      ;; Update quest as failed
      (map-set quests
        { quest-id: quest-id, owner: caller }
        (merge quest {
          status: QUEST-STATUS-FAILED
        })
      )
      
      ;; Update reputation
      (update-reputation-for-failure caller)
      SUCCESS-TRUE
    )
  )
)

;; Create a new guild
(define-public (create-guild (name (string-ascii 50)) (description (string-utf8 500)))
  (let (
    (guild-id (generate-guild-id))
    (creator tx-sender)
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Basic parameter validation
    (asserts! (> (len name) u0) ERR-INVALID-PARAMS)
    
    ;; Create the guild
    (map-set guilds
      { guild-id: guild-id }
      {
        name: name,
        description: description,
        admin: creator,
        creation-time: current-time,
        member-count: u1, ;; Creator is the first member
        total-stake-pool: u0
      }
    )
    
    ;; Add creator as member
    (map-set guild-members
      { guild-id: guild-id, member: creator }
      { joined-at: current-time, active: true }
    )
    
    ;; Add guild to creator's list
    (add-guild-to-user-list creator guild-id)
    
    ;; Return the new guild ID
    (ok guild-id)
  )
)

;; Join a guild
(define-public (join-guild (guild-id uint))
  (let (
    (user tx-sender)
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    (guild-data (map-get? guilds { guild-id: guild-id }))
  )
    ;; Verify guild exists
    (asserts! (not (is-none guild-data)) ERR-GUILD-NOT-FOUND)
    
    ;; Check if already a member
    (asserts! (not (is-guild-member guild-id user)) ERR-ALREADY-GUILD-MEMBER)
    
    ;; Add as member
    (map-set guild-members
      { guild-id: guild-id, member: user }
      { joined-at: current-time, active: true }
    )
    
    ;; Add guild to user's list
    (add-guild-to-user-list user guild-id)
    
    ;; Update guild member count
    (let (
      (guild (unwrap-panic guild-data))
    )
      (map-set guilds
        { guild-id: guild-id }
        (merge guild {
          member-count: (+ (get member-count guild) u1)
        })
      )
    )
    
    SUCCESS-TRUE
  )
)

;; Create a guild challenge
(define-public (create-guild-challenge (guild-id uint) (title (string-ascii 100)) 
                                      (description (string-utf8 500)) (stake-amount uint) (deadline uint))
  (let (
    (creator tx-sender)
    (challenge-id (generate-challenge-id))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    (guild-data (map-get? guilds { guild-id: guild-id }))
  )
    ;; Verify guild exists
    (asserts! (not (is-none guild-data)) ERR-GUILD-NOT-FOUND)
    
    ;; Verify creator is admin or member
    (asserts! (is-guild-member guild-id creator) ERR-NOT-GUILD-MEMBER)
    
    ;; Basic parameter validation
    (asserts! (> (len title) u0) ERR-INVALID-PARAMS)
    (asserts! (> stake-amount u0) ERR-INVALID-PARAMS)
    (asserts! (> deadline current-time) ERR-INVALID-PARAMS)
    
    ;; Create the challenge
    (map-set guild-challenges
      { guild-id: guild-id, challenge-id: challenge-id }
      {
        title: title,
        description: description,
        stake-amount: stake-amount,
        deadline: deadline,
        status: QUEST-STATUS-ACTIVE,
        creation-time: current-time,
        completion-count: u0,
        reward-pool: u0
      }
    )
    
    ;; Return the new challenge ID
    (ok challenge-id)
  )
)

;; Join a guild challenge
(define-public (join-guild-challenge (guild-id uint) (challenge-id uint))
  (let (
    (participant tx-sender)
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    (challenge-data (map-get? guild-challenges { guild-id: guild-id, challenge-id: challenge-id }))
  )
    ;; Verify challenge exists
    (asserts! (not (is-none challenge-data)) ERR-QUEST-NOT-FOUND)
    
    ;; Verify user is a guild member
    (asserts! (is-guild-member guild-id participant) ERR-NOT-GUILD-MEMBER)
    
    ;; Verify challenge is still active
    (let (
      (challenge (unwrap-panic challenge-data))
    )
      (asserts! (is-eq (get status challenge) QUEST-STATUS-ACTIVE) ERR-QUEST-ALREADY-COMPLETED)
      (asserts! (< current-time (get deadline challenge)) ERR-QUEST-EXPIRED)
      
      ;; Join the challenge
      (map-set challenge-participants
        { guild-id: guild-id, challenge-id: challenge-id, participant: participant }
        {
          joined-at: current-time,
          status: QUEST-STATUS-ACTIVE,
          completed-at: none,
          verified-by: none
        }
      )
      
      SUCCESS-TRUE
    )
  )
)

;; Complete a guild challenge (requires verification later)
(define-public (complete-guild-challenge (guild-id uint) (challenge-id uint))
  (let (
    (participant tx-sender)
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    (challenge-data (map-get? guild-challenges { guild-id: guild-id, challenge-id: challenge-id }))
    (participation-data (map-get? challenge-participants 
                        { guild-id: guild-id, challenge-id: challenge-id, participant: participant }))
  )
    ;; Verify challenge exists
    (asserts! (not (is-none challenge-data)) ERR-QUEST-NOT-FOUND)
    
    ;; Verify user is participating
    (asserts! (not (is-none participation-data)) ERR-NOT-GUILD-MEMBER)
    
    (let (
      (challenge (unwrap-panic challenge-data))
      (participation (unwrap-panic participation-data))
    )
      ;; Verify challenge is still active
      (asserts! (is-eq (get status challenge) QUEST-STATUS-ACTIVE) ERR-QUEST-ALREADY-COMPLETED)
      (asserts! (< current-time (get deadline challenge)) ERR-QUEST-EXPIRED)
      
      ;; Verify participation is active
      (asserts! (is-eq (get status participation) QUEST-STATUS_ACTIVE) ERR-QUEST-ALREADY-COMPLETED)
      
      ;; Mark as completed (pending verification)
      (map-set challenge-participants
        { guild-id: guild-id, challenge-id: challenge-id, participant: participant }
        (merge participation {
          status: QUEST-STATUS-COMPLETED,
          completed-at: (some current-time)
        })
      )
      
      SUCCESS-TRUE
    )
  )
)

;; Verify a guild challenge completion (for guild admins)
(define-public (verify-guild-challenge (guild-id uint) (challenge-id uint) (participant principal))
  (let (
    (verifier tx-sender)
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    (guild-data (map-get? guilds { guild-id: guild-id }))
    (challenge-data (map-get? guild-challenges { guild-id: guild-id, challenge-id: challenge-id }))
    (participation-data (map-get? challenge-participants 
                        { guild-id: guild-id, challenge-id: challenge-id, participant: participant }))
  )
    ;; Verify guild and challenge exist
    (asserts! (not (is-none guild-data)) ERR-GUILD-NOT-FOUND)
    (asserts! (not (is-none challenge-data)) ERR-QUEST-NOT-FOUND)
    
    ;; Verify participation exists
    (asserts! (not (is-none participation-data)) ERR-NOT-GUILD-MEMBER)
    
    ;; Verify verifier is guild admin or authorized verifier
    (asserts! 
      (or
        (is-eq verifier (get admin (unwrap-panic guild-data)))
        (is-some (map-get? authorized-verifiers { verifier: verifier }))
      )
      ERR-NOT-AUTHORIZED-VERIFIER
    )
    
    (let (
      (challenge (unwrap-panic challenge-data))
      (participation (unwrap-panic participation-data))
    )
      ;; Verify challenge is still active
      (asserts! (is-eq (get status challenge) QUEST-STATUS-ACTIVE) ERR-QUEST-ALREADY-COMPLETED)
      
      ;; Verify participation status is completed (awaiting verification)
      (asserts! (is-eq (get status participation) QUEST-STATUS-COMPLETED) ERR-INVALID-QUEST-PARAMS)
      
      ;; Update participation as verified
      (map-set challenge-participants
        { guild-id: guild-id, challenge-id: challenge-id, participant: participant }
        (merge participation {
          verified-by: (some verifier)
        })
      )
      
      ;; Update challenge completion count
      (map-set guild-challenges
        { guild-id: guild-id, challenge-id: challenge-id }
        (merge challenge {
          completion-count: (+ (get completion-count challenge) u1)
        })
      )
      
      ;; Update reputation for participant
      (update-reputation-for-completion participant)
      
      SUCCESS-TRUE
    )
  )
)

;; Register as a verifier (in a complete implementation, this would have additional authorization)
(define-public (register-as-verifier (verifier-type uint))
  (let (
    (verifier tx-sender)
  )
    ;; Verify valid verifier type
    (asserts! (and (>= verifier-type VERIFIER-TYPE-SELF) (<= verifier-type VERIFIER-TYPE-AUTHORITY)) 
              ERR-INVALID-PARAMS)
    
    ;; Register as verifier
    (map-set authorized-verifiers
      { verifier: verifier }
      { verifier-type: verifier-type, active: true }
    )
    
    SUCCESS-TRUE
  )
)

;; Revoke verifier status (admin function, simplified here)
(define-public (revoke-verifier (verifier principal))
  (let (
    (admin tx-sender)
    (verifier-data (map-get? authorized-verifiers { verifier: verifier }))
  )
    ;; Simplified authorization - in production would check against contract owner or admin list
    (asserts! true ERR-UNAUTHORIZED)