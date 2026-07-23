// ============================================================
//  NovaCont Lite — Minimal Escrow for TON
//  Language : Tact
//  Network  : TON Mainnet / Testnet
//  Version  : 1.1.1
//
//  Design principles:
//    - Admin settlement for dispute resolution
//    - Native TON only (no Jetton complexity)
//    - Three parties: client, provider, owner/admin (platform fee only)
//    - Pull pattern: funds released via explicit approve/cancel
//    - Timeout: provider can claim if client silent after delivery
// ============================================================

import "@stdlib/deploy";

// ─────────────────────────────────────────
//  MESSAGES
// ─────────────────────────────────────────

message CreateEscrow {
    provider:      Address;
    description:   String;          // Short description (stored on-chain)
    acceptDays:    Int as uint16;   // Days provider has to accept
    acceptHours:   Int as uint16;   // Hours provider has to accept
    deliveryDays:  Int as uint16;   // Days provider has to deliver (after acceptance)
    deliveryHours: Int as uint16;   // Hours provider has to deliver
}

message AcceptEscrow {
    escrowId: Int as uint64;
}

message RejectEscrow {
    escrowId: Int as uint64;
}

message DeliverEscrow {
    escrowId:    Int as uint64;
    evidenceUrl: String;          // IPFS / URL pointing to proof of work
}

message ReleaseEscrow {
    escrowId: Int as uint64;
}

message CancelEscrow {
    escrowId: Int as uint64;
}

message ClaimTimeout {
    escrowId: Int as uint64;
}

// Admin / Dispute Messages
message AddAdmin {
    admin: Address;
}

message RemoveAdmin {
    admin: Address;
}

message RaiseDispute {
    escrowId: Int as uint64;
    reason: String;
}

message AddSupport {
    support: Address;
}

message RemoveSupport {
    support: Address;
}

message ResolveDispute {
    escrowId:       Int as uint64;
    clientShareBps: Int as uint16; // 0 to 10000 (Basis points for client's refund portion)
    reason:         String;
}

// ─────────────────────────────────────────
//  STRUCTS
// ─────────────────────────────────────────

struct EscrowData {
    client:           Address;
    provider:         Address;
    agreedTon:        Int as coins;   // Agreed price in nanoTON
    totalLocked:      Int as coins;   // Actual deposit (1x or 1.25x)
    isExtraDeposit:   Bool;           // True if < 10 TON → 1.25x deposit required
    description:      String;
    evidenceUrl:      String;
    state:            Int as uint8;   // 0=Created 1=Accepted 2=Delivered 3=Completed 4=Cancelled 5=Disputed
    acceptDeadline:   Int as uint64;  // Unix timestamp
    deliveryDeadline: Int as uint64;  // Unix timestamp (set after acceptance)
    deliveryTime:     Int as uint64;  // Unix timestamp (set after delivery)
    acceptTime:       Int as uint64;  // Unix timestamp (set after acceptance)
    createdAt:        Int as uint64;
    deliveryDuration: Int as uint64;  // Store total delivery duration in seconds
    resolutionReason: String;
    disputeReason:    String;
    resolvedClientShareBps: Int as uint16;
    assignedSupport:  Address?;
}

// ─────────────────────────────────────────
//  CONSTANTS
// ─────────────────────────────────────────

const STATE_CREATED:   Int = 0;
const STATE_ACCEPTED:  Int = 1;
const STATE_DELIVERED: Int = 2;
const STATE_COMPLETED: Int = 3;
const STATE_CANCELLED: Int = 4;
const STATE_DISPUTED:  Int = 5;

const PLATFORM_FEE_BPS: Int = 300; // 3%

const EXTRA_DEPOSIT_THRESHOLD: Int = 10000000000; // 10 TON in nanoTON

const REVIEW_TIMEOUT: Int = 604800; // 7 days in seconds

const STORAGE_RESERVE: Int = 50000000; // 0.05 TON

// ─────────────────────────────────────────
//  CONTRACT
// ─────────────────────────────────────────

contract NovaContLite with Deployable {

    owner: Address;
    admins: map<Address, Bool>;
    escrows: map<Int, EscrowData>;
    escrowCount: Int as uint64;
    supportCount: Int as uint8;
    supports: map<Int, Address>;
    supportIndex: map<Address, Int as uint8>;
    nextSupportAssign: Int as uint8;

    init(owner: Address) {
        self.owner = owner;
        self.escrowCount = 0;
        self.admins.set(owner, true);
        self.supportCount = 0;
        self.nextSupportAssign = 0;
    }

    // ─────────────────────────────────────
    //  ADMIN MANAGEMENT
    // ─────────────────────────────────────

    receive(msg: AddAdmin) {
        require(context().sender == self.owner, "Only owner can add admins");
        self.admins.set(msg.admin, true);
    }

    receive(msg: RemoveAdmin) {
        require(context().sender == self.owner, "Only owner can remove admins");
        self.admins.set(msg.admin, false);
    }



    receive(msg: AddSupport) {
        require(context().sender == self.owner, "Only owner can add supports");
        require(self.supportCount < 50, "Max 50 supports");
        let idx: Int? = self.supportIndex.get(msg.support);
        require(idx == null, "Already a support");

        self.supports.set(self.supportCount, msg.support);
        self.supportIndex.set(msg.support, self.supportCount);
        self.supportCount = self.supportCount + 1;
    }

    receive(msg: RemoveSupport) {
        require(context().sender == self.owner, "Only owner can remove supports");
        let idx: Int? = self.supportIndex.get(msg.support);
        require(idx != null, "Not a support");

        let lastIdx: Int = self.supportCount - 1;
        let lastSupport: Address = self.supports.get(lastIdx)!!;

        if (idx!! != lastIdx) {
            self.supports.set(idx!!, lastSupport);
            self.supportIndex.set(lastSupport, idx!!);
        }

        self.supports.set(lastIdx, null);
        self.supportIndex.set(msg.support, null);
        self.supportCount = lastIdx;

        if (self.supportCount > 0 && self.nextSupportAssign >= self.supportCount) {
            self.nextSupportAssign = 0;
        } else if (self.supportCount == 0) {
            self.nextSupportAssign = 0;
        }
    }

    // ─────────────────────────────────────
    //  CREATE ESCROW
    // ─────────────────────────────────────

    receive(msg: CreateEscrow) {
        let ctx: Context = context();
        let sender: Address = ctx.sender;
        let attached: Int = ctx.value;

        require(msg.provider != sender, "Client cannot be provider");
        require((msg.acceptDays > 0 || msg.acceptHours > 0), "Invalid accept time");
        require((msg.deliveryDays > 0 || msg.deliveryHours > 0), "Invalid delivery time");

        let isExtra: Bool = attached < EXTRA_DEPOSIT_THRESHOLD;
        let agreedTon: Int = isExtra ? (attached * 4 / 5) : attached;

        require(agreedTon > 0, "Agreed price must be > 0");

        let acceptDuration: Int = (msg.acceptDays * 86400) + (msg.acceptHours * 3600);
        let deliveryDuration: Int = (msg.deliveryDays * 86400) + (msg.deliveryHours * 3600);

        let escrow: EscrowData = EscrowData{
            client:          sender,
            provider:        msg.provider,
            agreedTon:       agreedTon,
            totalLocked:     attached,
            isExtraDeposit:  isExtra,
            description:     msg.description,
            evidenceUrl:     "",
            state:           STATE_CREATED,
            acceptDeadline:  now() + acceptDuration,
            deliveryDeadline: 0,
            deliveryTime:    0,
            acceptTime:      0,
            createdAt:       now(),
            deliveryDuration: deliveryDuration,
            resolutionReason: "",
            disputeReason:    "",
            resolvedClientShareBps: 0,
            assignedSupport:  null
        };

        let id: Int = self.escrowCount;

        self.escrows.set(id, escrow);
        self.escrowCount = self.escrowCount + 1;

        emit(EscrowCreated{
            escrowId: id,
            client:   sender,
            provider: msg.provider,
            agreedTon: agreedTon,
            totalLocked: attached,
            isExtraDeposit: isExtra
        }.toCell());
    }

    // ─────────────────────────────────────
    //  ACCEPT ESCROW
    // ─────────────────────────────────────

    receive(msg: AcceptEscrow) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        require(sender == escrow.provider, "Only provider can accept");
        require(escrow.state == STATE_CREATED, "Not in Created state");
        require(now() <= escrow.acceptDeadline, "Accept deadline passed");

        escrow.state = STATE_ACCEPTED;
        escrow.acceptTime = now();
        escrow.deliveryDeadline = now() + escrow.deliveryDuration;
        self.escrows.set(msg.escrowId, escrow);

        emit(EscrowAccepted{
            escrowId:         msg.escrowId,
            deliveryDeadline: escrow.deliveryDeadline
        }.toCell());

        self.reply("Excess gas refund".asComment());
    }

    // ─────────────────────────────────────
    //  REJECT ESCROW
    // ─────────────────────────────────────

    receive(msg: RejectEscrow) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        require(sender == escrow.provider, "Only provider can reject");
        require(escrow.state == STATE_CREATED, "Not in Created state");

        escrow.state = STATE_CANCELLED;
        self.escrows.set(msg.escrowId, escrow);

        send(SendParameters{
            to:    escrow.client,
            value: escrow.totalLocked - STORAGE_RESERVE,
            mode:  SendBounceIfActionFail,
            body:  "NovaCont: Escrow rejected. Full refund sent.".asComment()
        });

        emit(EscrowCancelled{
            escrowId:     msg.escrowId,
            clientRefund: escrow.totalLocked,
            reason:       "Provider rejected"
        }.toCell());
    }

    // ─────────────────────────────────────
    //  DELIVER WORK
    // ─────────────────────────────────────

    receive(msg: DeliverEscrow) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        require(sender == escrow.provider, "Only provider can deliver");
        require(escrow.state == STATE_ACCEPTED, "Not in Accepted state");
        require(now() <= escrow.deliveryDeadline, "Delivery deadline passed");
        require(msg.evidenceUrl != "", "Evidence URL required");

        escrow.state = STATE_DELIVERED;
        escrow.deliveryTime = now();
        escrow.evidenceUrl = msg.evidenceUrl;
        self.escrows.set(msg.escrowId, escrow);

        emit(WorkDelivered{
            escrowId:    msg.escrowId,
            evidenceUrl: msg.evidenceUrl,
            deliveryTime: now()
        }.toCell());

        self.reply("Excess gas refund".asComment());
    }

    // ─────────────────────────────────────
    //  RELEASE ESCROW (Approve)
    // ─────────────────────────────────────

    receive(msg: ReleaseEscrow) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        require(sender == escrow.client, "Only client can release");
        require(escrow.state == STATE_DELIVERED, "Not in Delivered state");

        escrow.state = STATE_COMPLETED;
        self.escrows.set(msg.escrowId, escrow);

        self.distributeFunds(msg.escrowId, escrow, 0); // 0 clientShare means 100% provider

        emit(EscrowCompleted{
            escrowId: msg.escrowId
        }.toCell());

        self.reply("Excess gas refund".asComment());
    }

    // ─────────────────────────────────────
    //  CANCEL ESCROW
    // ─────────────────────────────────────

    receive(msg: CancelEscrow) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        require(sender == escrow.client, "Only client can cancel");
        require(
            escrow.state == STATE_CREATED || escrow.state == STATE_ACCEPTED,
            "Cannot cancel at this stage"
        );

        let wasNotYetAccepted: Bool = (escrow.state == STATE_CREATED || escrow.acceptTime == 0);

        escrow.state = STATE_CANCELLED;
        self.escrows.set(msg.escrowId, escrow);

        if (wasNotYetAccepted) {
            send(SendParameters{
                to:    escrow.client,
                value: escrow.totalLocked - STORAGE_RESERVE,
                mode:  SendBounceIfActionFail,
                body:  "NovaCont: Escrow cancelled. Full refund.".asComment()
            });

            emit(EscrowCancelled{
                escrowId:     msg.escrowId,
                clientRefund: escrow.totalLocked,
                reason:       "Cancelled before acceptance"
            }.toCell());
        } else {
            let totalDuration: Int = escrow.deliveryDeadline - escrow.acceptTime;
            let elapsed: Int = now() - escrow.acceptTime;

            if (now() > escrow.deliveryDeadline) {
                // If delivery deadline has passed without delivery, client gets 100% refund
                self.distributeFunds(msg.escrowId, escrow, 10000); // 10000 BPS = 100%
            } else if (elapsed > totalDuration / 2) {
                // Provider gets 50%, client gets 50% (if cancelled halfway but before deadline)
                self.distributeFunds(msg.escrowId, escrow, 5000); // 5000 BPS = 50%
            } else {
                // Client gets 100% refund since 50% time hasn't passed
                self.distributeFunds(msg.escrowId, escrow, 10000); // 10000 BPS = 100%
            }
        }

        self.reply("Excess gas refund".asComment());
    }

    // ─────────────────────────────────────
    //  CLAIM TIMEOUT
    // ─────────────────────────────────────

    receive(msg: ClaimTimeout) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        require(sender == escrow.provider, "Only provider can claim timeout");
        require(escrow.state == STATE_DELIVERED, "Not in Delivered state");
        require(now() >= escrow.deliveryTime + REVIEW_TIMEOUT, "Review period still active");

        escrow.state = STATE_COMPLETED;
        self.escrows.set(msg.escrowId, escrow);

        self.distributeFunds(msg.escrowId, escrow, 0);

        emit(TimeoutClaimed{
            escrowId: msg.escrowId
        }.toCell());
    }

    // ─────────────────────────────────────
    //  DISPUTE MANAGEMENT
    // ─────────────────────────────────────

    receive(msg: RaiseDispute) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        // Either client or provider can raise a dispute if it's Delivered (e.g. client unhappy)
        // Or if it's Accepted (e.g. provider is stuck, or client wants out but passed 50% time)
        require(sender == escrow.client || sender == escrow.provider, "Only parties can dispute");
        require(escrow.state == STATE_ACCEPTED || escrow.state == STATE_DELIVERED, "Cannot dispute in this state");

        escrow.state = STATE_DISPUTED;
        escrow.disputeReason = msg.reason;

        if (self.supportCount > 0) {
            let assigned: Address = self.supports.get(self.nextSupportAssign)!!;
            escrow.assignedSupport = assigned;
            self.nextSupportAssign = (self.nextSupportAssign + 1) % self.supportCount;
        } else {
            escrow.assignedSupport = null;
        }

        self.escrows.set(msg.escrowId, escrow);

        emit(DisputeRaised{
            escrowId: msg.escrowId,
            raiser: sender
        }.toCell());
    }

    receive(msg: ResolveDispute) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;
        
        let isAuthorized: Bool = (sender == self.owner) || (escrow.assignedSupport != null && sender == escrow.assignedSupport!!);
        require(isAuthorized, "Not authorized to resolve this dispute");
        require(escrow.state == STATE_DISPUTED, "Escrow not in disputed state");
        require(msg.clientShareBps >= 0 && msg.clientShareBps <= 10000, "Invalid share BPS");

        escrow.state = STATE_COMPLETED;
        escrow.resolutionReason = msg.reason;
        escrow.resolvedClientShareBps = msg.clientShareBps;
        self.escrows.set(msg.escrowId, escrow);

        self.distributeFunds(msg.escrowId, escrow, msg.clientShareBps);

        emit(DisputeResolved{
            escrowId: msg.escrowId,
            clientShareBps: msg.clientShareBps
        }.toCell());

        self.reply("Excess gas refund".asComment());
    }

    // ─────────────────────────────────────
    //  INTERNAL: Distribute funds
    // ─────────────────────────────────────

    fun distributeFunds(escrowId: Int, escrow: EscrowData, clientShareBps: Int) {
        let providerShareBps: Int = 10000 - clientShareBps;
        
        let fee: Int = (escrow.agreedTon * PLATFORM_FEE_BPS) / 10000;
        let netAgreedTon: Int = escrow.agreedTon - fee;

        let providerNet: Int = (netAgreedTon * providerShareBps) / 10000;
        let clientRefundFromAgreed: Int = (netAgreedTon * clientShareBps) / 10000;

        let clientExtraRefund: Int = escrow.totalLocked - escrow.agreedTon;
        let clientRefund: Int = clientRefundFromAgreed + clientExtraRefund;

        if (providerNet > STORAGE_RESERVE) {
            send(SendParameters{
                to:    escrow.provider,
                value: providerNet - STORAGE_RESERVE,
                mode:  SendBounceIfActionFail,
                body:  "NovaCont: Provider share".asComment()
            });
        }

        if (fee > 0) {
            send(SendParameters{
                to:    self.owner,
                value: fee,
                mode:  SendBounceIfActionFail,
                body:  "NovaCont: Platform fee".asComment()
            });
        }

        if (clientRefund > STORAGE_RESERVE) {
            send(SendParameters{
                to:    escrow.client,
                value: clientRefund - STORAGE_RESERVE,
                mode:  SendBounceIfActionFail,
                body:  "NovaCont: Client refund".asComment()
            });
        }
    }

    // ─────────────────────────────────────
    //  INTERNAL: Require escrow exists
    // ─────────────────────────────────────

    fun requireEscrow(escrowId: Int): EscrowData {
        let escrow: EscrowData? = self.escrows.get(escrowId);
        require(escrow != null, "Escrow not found");
        return escrow!!;
    }

    // ─────────────────────────────────────
    //  GETTERS
    // ─────────────────────────────────────

    get fun getEscrow(escrowId: Int): EscrowData? {
        return self.escrows.get(escrowId);
    }

    get fun getEscrowCount(): Int {
        return self.escrowCount;
    }

    get fun getOwner(): Address {
        return self.owner;
    }

    get fun isAdmin(addr: Address): Bool {
        let a: Bool? = self.admins.get(addr);
        if (a == null) { return false; }
        return a!!;
    }
}

// ─────────────────────────────────────────
//  EVENTS
// ─────────────────────────────────────────

message EscrowCreated {
    escrowId:       Int as uint64;
    client:         Address;
    provider:       Address;
    agreedTon:      Int as coins;
    totalLocked:    Int as coins;
    isExtraDeposit: Bool;
}

message EscrowAccepted {
    escrowId:         Int as uint64;
    deliveryDeadline: Int as uint64;
}

message WorkDelivered {
    escrowId:     Int as uint64;
    evidenceUrl:  String;
    deliveryTime: Int as uint64;
}

message EscrowCompleted {
    escrowId: Int as uint64;
}

message EscrowCancelled {
    escrowId:     Int as uint64;
    clientRefund: Int as coins;
    reason:       String;
}

message TimeoutClaimed {
    escrowId: Int as uint64;
}

message DisputeRaised {
    escrowId: Int as uint64;
    raiser:   Address;
}

message DisputeResolved {
    escrowId:       Int as uint64;
    clientShareBps: Int as uint16;
}
