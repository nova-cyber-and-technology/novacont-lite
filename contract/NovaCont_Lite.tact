// ============================================================
//  NovaCont Lite — Minimal Escrow for TON
//  Language : Tact
//  Network  : TON Mainnet / Testnet
//  Version  : 1.2.0
// ============================================================

import "@stdlib/deploy";

// ─────────────────────────────────────────
//  MESSAGES
// ─────────────────────────────────────────

message CreateEscrow {
    provider:      Address;
    agreedTon:     Int as coins;    
    description:   String;
    acceptDays:    Int as uint16;
    acceptHours:   Int as uint16;
    deliveryDays:  Int as uint16;
    deliveryHours: Int as uint16;
}

message AcceptEscrow  { escrowId: Int as uint64; }
message RejectEscrow  { escrowId: Int as uint64; }
message ReleaseEscrow { escrowId: Int as uint64; }
message CancelEscrow  { escrowId: Int as uint64; }
message ClaimTimeout  { escrowId: Int as uint64; }

message DeliverEscrow {
    escrowId:    Int as uint64;
    evidenceUrl: String;
}

// Dispute messages
message RaiseDispute {
    escrowId: Int as uint64;
    reason:   String;
}

message ResolveDispute {
    escrowId:       Int as uint64;
    clientShareBps: Int as uint16;  // 0..10000, client's refund portion
    reason:         String;
}

// [A] Either party may settle a stalled dispute after the timeout
message ClaimDisputeTimeout { escrowId: Int as uint64; }

// [C] Owner may reassign a dispute whose reviewer is gone
message ReassignDispute { escrowId: Int as uint64; }

// Support management
message AddSupport    { support: Address; }
message RemoveSupport { support: Address; }

// [B] Ownership and pause
message TransferOwnership { newOwner: Address; }
message AcceptOwnership   { }
message SetPaused         { paused: Bool; }

// ─────────────────────────────────────────
//  STRUCTS
// ─────────────────────────────────────────

struct EscrowData {
    client:           Address;
    provider:         Address;
    agreedTon:        Int as coins;
    totalLocked:      Int as coins;   // exact deposit held for this escrow
    isExtraDeposit:   Bool;           // true if agreedTon < 10 TON -> 1.25x
    description:      String;
    evidenceUrl:      String;
    state:            Int as uint8;   // 0=Created 1=Accepted 2=Delivered 3=Completed 4=Cancelled 5=Disputed
    acceptDeadline:   Int as uint64;
    deliveryDeadline: Int as uint64;
    deliveryTime:     Int as uint64;
    acceptTime:       Int as uint64;
    createdAt:        Int as uint64;
    deliveryDuration: Int as uint64;
    resolutionReason: String;
    disputeReason:    String;
    disputeRaisedAt:  Int as uint64;  
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

const PLATFORM_FEE_BPS: Int = 300;              // 3%
const EXTRA_DEPOSIT_THRESHOLD: Int = 10000000000; // 10 TON
const REVIEW_TIMEOUT: Int = 604800;             // 7 days
const DISPUTE_TIMEOUT: Int = 2592000;           
const DISPUTE_TIMEOUT_CLIENT_BPS: Int = 5000;   

// [E] Gas budget bounds. The surplus above the required deposit funds
//     the settlement messages for this escrow. Upper bound prevents a
//     user from accidentally overpaying a large amount.
const MIN_GAS_BUDGET: Int = 50000000;   // 0.05 TON
const MAX_GAS_BUDGET: Int = 300000000;  // 0.3 TON

const MAX_SUPPORTS: Int = 50;

// ─────────────────────────────────────────
//  CONTRACT
// ─────────────────────────────────────────

contract NovaContLite with Deployable {

    owner: Address;
    pendingOwner: Address?;   
    paused: Bool;             

    escrows: map<Int, EscrowData>;
    escrowCount: Int as uint64;

    supports: map<Int, Address>;
    supportIndex: map<Address, Int as uint8>;
    supportCount: Int as uint8;
    nextSupportAssign: Int as uint8;

    init(owner: Address) {
        self.owner = owner;
        self.pendingOwner = null;
        self.paused = false;
        self.escrowCount = 0;
        self.supportCount = 0;
        self.nextSupportAssign = 0;
    }

    // ─────────────────────────────────────
    // OWNERSHIP AND PAUSE
    // ─────────────────────────────────────

    receive(msg: TransferOwnership) {
        require(context().sender == self.owner, "Only owner");
        self.pendingOwner = msg.newOwner;
        emit(OwnershipTransferStarted{ newOwner: msg.newOwner }.toCell());
    }

    receive(_: AcceptOwnership) {
        let sender: Address = context().sender;
        require(self.pendingOwner != null, "No pending transfer");
        require(sender == self.pendingOwner!!, "Only pending owner");

        let previous: Address = self.owner;
        self.owner = sender;
        self.pendingOwner = null;

        emit(OwnershipTransferred{ previousOwner: previous, newOwner: sender }.toCell());
    }

    receive(msg: SetPaused) {
        require(context().sender == self.owner, "Only owner");
        self.paused = msg.paused;
        emit(PausedChanged{ paused: msg.paused }.toCell());
    }

    // Accept plain transfers so the owner can top up the gas/storage balance.
    receive() { }

    // ─────────────────────────────────────
    //  SUPPORT MANAGEMENT
    // ─────────────────────────────────────

    receive(msg: AddSupport) {
        require(context().sender == self.owner, "Only owner");
        require(self.supportCount < MAX_SUPPORTS, "Max supports reached");
        require(self.supportIndex.get(msg.support) == null, "Already a support");

        self.supports.set(self.supportCount, msg.support);
        self.supportIndex.set(msg.support, self.supportCount);
        self.supportCount = self.supportCount + 1;

        emit(SupportAdded{ support: msg.support }.toCell());
    }

    receive(msg: RemoveSupport) {
        require(context().sender == self.owner, "Only owner");
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

        if (self.supportCount == 0 || self.nextSupportAssign >= self.supportCount) {
            self.nextSupportAssign = 0;
        }

        emit(SupportRemoved{ support: msg.support }.toCell());
    }

    // ─────────────────────────────────────
    //  CREATE ESCROW
    // ─────────────────────────────────────

    receive(msg: CreateEscrow) {
        require(!self.paused, "Contract is paused");

        let ctx: Context = context();
        let sender: Address = ctx.sender;

        require(msg.provider != sender, "Client cannot be provider");
        require(msg.agreedTon > 0, "Agreed price must be > 0");
        require((msg.acceptDays > 0 || msg.acceptHours > 0), "Invalid accept time");
        require((msg.deliveryDays > 0 || msg.deliveryHours > 0), "Invalid delivery time");

        // [E][F] Deposit tier is derived from the AGREED amount, not from
        // what was attached. Every agreed amount is now reachable.
        let isExtra: Bool = msg.agreedTon < EXTRA_DEPOSIT_THRESHOLD;
        let required: Int = isExtra ? (msg.agreedTon * 125 / 100) : msg.agreedTon;

        require(ctx.value >= required + MIN_GAS_BUDGET, "Insufficient deposit");
        require(ctx.value <= required + MAX_GAS_BUDGET, "Overpayment: reduce attached value");

        let acceptDuration: Int   = (msg.acceptDays * 86400) + (msg.acceptHours * 3600);
        let deliveryDuration: Int = (msg.deliveryDays * 86400) + (msg.deliveryHours * 3600);

        let escrow: EscrowData = EscrowData{
            client:           sender,
            provider:         msg.provider,
            agreedTon:        msg.agreedTon,
            totalLocked:      required,          // [E] exact, gas surplus excluded
            isExtraDeposit:   isExtra,
            description:      msg.description,
            evidenceUrl:      "",
            state:            STATE_CREATED,
            acceptDeadline:   now() + acceptDuration,
            deliveryDeadline: 0,
            deliveryTime:     0,
            acceptTime:       0,
            createdAt:        now(),
            deliveryDuration: deliveryDuration,
            resolutionReason: "",
            disputeReason:    "",
            disputeRaisedAt:  0,
            resolvedClientShareBps: 0,
            assignedSupport:  null
        };

        let id: Int = self.escrowCount;
        self.escrows.set(id, escrow);
        self.escrowCount = self.escrowCount + 1;

        emit(EscrowCreated{
            escrowId:       id,
            client:         sender,
            provider:       msg.provider,
            agreedTon:      msg.agreedTon,
            totalLocked:    required,
            isExtraDeposit: isExtra
        }.toCell());
    }

    // ─────────────────────────────────────
    //  ACCEPT / REJECT
    // ─────────────────────────────────────

    receive(msg: AcceptEscrow) {
        require(!self.paused, "Contract is paused");

        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        require(context().sender == escrow.provider, "Only provider can accept");
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
    }

    receive(msg: RejectEscrow) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        require(context().sender == escrow.provider, "Only provider can reject");
        require(escrow.state == STATE_CREATED, "Not in Created state");

        escrow.state = STATE_CANCELLED;
        self.escrows.set(msg.escrowId, escrow);

        self.refundFull(msg.escrowId, escrow, "Provider rejected");
    }

    // ─────────────────────────────────────
    //  DELIVER
    // ─────────────────────────────────────

    receive(msg: DeliverEscrow) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        require(context().sender == escrow.provider, "Only provider can deliver");
        require(escrow.state == STATE_ACCEPTED, "Not in Accepted state");
        require(now() <= escrow.deliveryDeadline, "Delivery deadline passed");
        require(msg.evidenceUrl != "", "Evidence URL required");

        escrow.state = STATE_DELIVERED;
        escrow.deliveryTime = now();
        escrow.evidenceUrl = msg.evidenceUrl;
        self.escrows.set(msg.escrowId, escrow);

        emit(WorkDelivered{
            escrowId:     msg.escrowId,
            evidenceUrl:  msg.evidenceUrl,
            deliveryTime: escrow.deliveryTime
        }.toCell());
    }

    // ─────────────────────────────────────
    //  RELEASE (client approves)
    // ─────────────────────────────────────

    receive(msg: ReleaseEscrow) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        require(context().sender == escrow.client, "Only client can release");
        require(escrow.state == STATE_DELIVERED, "Not in Delivered state");

        escrow.state = STATE_COMPLETED;
        self.escrows.set(msg.escrowId, escrow);

        self.distributeFunds(msg.escrowId, escrow, 0);

        emit(EscrowCompleted{ escrowId: msg.escrowId }.toCell());
    }

    // ─────────────────────────────────────
    //  CANCEL (client)
    // ─────────────────────────────────────

    receive(msg: CancelEscrow) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        require(context().sender == escrow.client, "Only client can cancel");
        require(
            escrow.state == STATE_CREATED || escrow.state == STATE_ACCEPTED,
            "Cannot cancel at this stage"
        );

        let notYetAccepted: Bool = (escrow.state == STATE_CREATED || escrow.acceptTime == 0);

        escrow.state = STATE_CANCELLED;
        self.escrows.set(msg.escrowId, escrow);

        if (notYetAccepted) {
            self.refundFull(msg.escrowId, escrow, "Cancelled before acceptance");
            return;
        }

        if (now() > escrow.deliveryDeadline) {
            // Provider never delivered: full refund, no fee.
            self.refundFull(msg.escrowId, escrow, "Delivery deadline passed");
            return;
        }

        let totalDuration: Int = escrow.deliveryDeadline - escrow.acceptTime;
        let elapsed: Int = now() - escrow.acceptTime;

        if (elapsed > totalDuration / 2) {
            self.distributeFunds(msg.escrowId, escrow, 5000);   // 50 / 50
        } else {
            self.refundFull(msg.escrowId, escrow, "Cancelled in first half");
        }
    }

    // ─────────────────────────────────────
    //  CLAIM TIMEOUT (provider, after review window)
    // ─────────────────────────────────────

    receive(msg: ClaimTimeout) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        require(context().sender == escrow.provider, "Only provider can claim timeout");
        require(escrow.state == STATE_DELIVERED, "Not in Delivered state");
        require(now() >= escrow.deliveryTime + REVIEW_TIMEOUT, "Review period still active");

        escrow.state = STATE_COMPLETED;
        self.escrows.set(msg.escrowId, escrow);

        self.distributeFunds(msg.escrowId, escrow, 0);

        emit(TimeoutClaimed{ escrowId: msg.escrowId }.toCell());
    }

    // ─────────────────────────────────────
    //  DISPUTES
    // ─────────────────────────────────────

    receive(msg: RaiseDispute) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        require(sender == escrow.client || sender == escrow.provider, "Only parties can dispute");
        require(
            escrow.state == STATE_ACCEPTED || escrow.state == STATE_DELIVERED,
            "Cannot dispute in this state"
        );

        escrow.state = STATE_DISPUTED;
        escrow.disputeReason = msg.reason;
        escrow.disputeRaisedAt = now();          // [A]
        escrow.assignedSupport = self.assignSupport();

        self.escrows.set(msg.escrowId, escrow);

        emit(DisputeRaised{
            escrowId:       msg.escrowId,
            raiser:         sender,
            assignedTo:     escrow.assignedSupport,
            autoSettleAfter: escrow.disputeRaisedAt + DISPUTE_TIMEOUT
        }.toCell());
    }

    receive(msg: ResolveDispute) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        // [C] A support must still be on the active roster. Removing a
        //     support now revokes their power over already-assigned cases.
        let isCurrentSupport: Bool =
            (escrow.assignedSupport != null)
            && (sender == escrow.assignedSupport!!)
            && (self.supportIndex.get(sender) != null);

        require(sender == self.owner || isCurrentSupport, "Not authorized to resolve");
        require(escrow.state == STATE_DISPUTED, "Escrow not in disputed state");
        require(msg.clientShareBps >= 0 && msg.clientShareBps <= 10000, "Invalid share BPS");

        escrow.state = STATE_COMPLETED;
        escrow.resolutionReason = msg.reason;
        escrow.resolvedClientShareBps = msg.clientShareBps;
        self.escrows.set(msg.escrowId, escrow);

        self.distributeFunds(msg.escrowId, escrow, msg.clientShareBps);

        emit(DisputeResolved{
            escrowId:       msg.escrowId,
            resolver:       sender,
            clientShareBps: msg.clientShareBps
        }.toCell());
    }

    // [C] Owner can hand an orphaned dispute to the current roster.
    receive(msg: ReassignDispute) {
        require(context().sender == self.owner, "Only owner");

        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        require(escrow.state == STATE_DISPUTED, "Escrow not in disputed state");

        escrow.assignedSupport = self.assignSupport();
        self.escrows.set(msg.escrowId, escrow);

        emit(DisputeReassigned{
            escrowId:   msg.escrowId,
            assignedTo: escrow.assignedSupport
        }.toCell());
    }

    // [A] Bounded exit from the disputed state. Callable by either party
    //     once the review window has expired. Not callable by us — this
    //     is deliberately outside our control.
    receive(msg: ClaimDisputeTimeout) {
        let escrow: EscrowData = self.requireEscrow(msg.escrowId);
        let sender: Address = context().sender;

        require(sender == escrow.client || sender == escrow.provider, "Only parties can claim");
        require(escrow.state == STATE_DISPUTED, "Escrow not in disputed state");
        require(escrow.disputeRaisedAt > 0, "No dispute timestamp");
        require(now() >= escrow.disputeRaisedAt + DISPUTE_TIMEOUT, "Dispute window still open");

        escrow.state = STATE_COMPLETED;
        escrow.resolutionReason = "Auto-settled: review timeout";
        escrow.resolvedClientShareBps = DISPUTE_TIMEOUT_CLIENT_BPS;
        self.escrows.set(msg.escrowId, escrow);

        self.distributeFunds(msg.escrowId, escrow, DISPUTE_TIMEOUT_CLIENT_BPS);

        emit(DisputeTimedOut{
            escrowId:       msg.escrowId,
            claimedBy:      sender,
            clientShareBps: DISPUTE_TIMEOUT_CLIENT_BPS
        }.toCell());
    }

    // ─────────────────────────────────────
    //  INTERNAL
    // ─────────────────────────────────────

    fun assignSupport(): Address? {
        if (self.supportCount == 0) {
            return null;
        }
        let assigned: Address = self.supports.get(self.nextSupportAssign)!!;
        self.nextSupportAssign = (self.nextSupportAssign + 1) % self.supportCount;
        return assigned;
    }

    // Full refund with no platform fee. Used wherever the provider
    // receives nothing and bears no partial performance.
    fun refundFull(escrowId: Int, escrow: EscrowData, reason: String) {
        send(SendParameters{
            to:    escrow.client,
            value: escrow.totalLocked,
            mode:  SendPayGasSeparately | SendBounceIfActionFail,
            body:  "NovaCont: Full refund".asComment()
        });

        emit(EscrowCancelled{
            escrowId:     escrowId,
            clientRefund: escrow.totalLocked,   // [H] matches what is sent
            reason:       reason
        }.toCell());
    }

    fun distributeFunds(escrowId: Int, escrow: EscrowData, clientShareBps: Int) {
        let providerShareBps: Int = 10000 - clientShareBps;

        // Fee is charged only where the provider actually receives funds.
        let fee: Int = 0;
        if (providerShareBps > 0) {
            fee = (escrow.agreedTon * PLATFORM_FEE_BPS) / 10000;
        }

        let netAgreed: Int = escrow.agreedTon - fee;
        let providerNet: Int = (netAgreed * providerShareBps) / 10000;
        let clientFromAgreed: Int = (netAgreed * clientShareBps) / 10000;
        let clientExtra: Int = escrow.totalLocked - escrow.agreedTon;
        let clientTotal: Int = clientFromAgreed + clientExtra;

        // [E] Amounts are exact. Forward fees are paid from the contract's
        //     own balance, funded by the gas budget collected at creation.
        if (providerNet > 0) {
            send(SendParameters{
                to:    escrow.provider,
                value: providerNet,
                mode:  SendPayGasSeparately | SendBounceIfActionFail,
                body:  "NovaCont: Provider share".asComment()
            });
        }

        if (fee > 0) {
            send(SendParameters{
                to:    self.owner,
                value: fee,
                mode:  SendPayGasSeparately | SendBounceIfActionFail,
                body:  "NovaCont: Platform fee".asComment()
            });
        }

        if (clientTotal > 0) {
            send(SendParameters{
                to:    escrow.client,
                value: clientTotal,
                mode:  SendPayGasSeparately | SendBounceIfActionFail,
                body:  "NovaCont: Client share".asComment()
            });
        }

        emit(FundsDistributed{        // [H] real amounts
            escrowId:       escrowId,
            providerAmount: providerNet,
            clientAmount:   clientTotal,
            feeAmount:      fee
        }.toCell());
    }

    fun requireEscrow(escrowId: Int): EscrowData {
        let escrow: EscrowData? = self.escrows.get(escrowId);
        require(escrow != null, "Escrow not found");
        return escrow!!;
    }

    // ─────────────────────────────────────
    //  GETTERS
    // ─────────────────────────────────────

    get fun getEscrow(escrowId: Int): EscrowData? { return self.escrows.get(escrowId); }
    get fun getEscrowCount(): Int { return self.escrowCount; }
    get fun getOwner(): Address { return self.owner; }
    get fun getPendingOwner(): Address? { return self.pendingOwner; }
    get fun isPaused(): Bool { return self.paused; }
    get fun getSupportCount(): Int { return self.supportCount; }
    get fun isSupport(addr: Address): Bool { return self.supportIndex.get(addr) != null; }
    get fun getSupportAt(index: Int): Address? { return self.supports.get(index); }
    get fun getVersion(): String { return "1.2.0"; }

    // Timestamp after which a stalled dispute can be auto-settled.
    // Returns null when the escrow is not disputed.
    get fun getDisputeDeadline(escrowId: Int): Int? {
        let e: EscrowData? = self.escrows.get(escrowId);
        if (e == null) { return null; }
        let escrow: EscrowData = e!!;
        if (escrow.state != STATE_DISPUTED) { return null; }
        return escrow.disputeRaisedAt + DISPUTE_TIMEOUT;
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

message EscrowCompleted { escrowId: Int as uint64; }

message EscrowCancelled {
    escrowId:     Int as uint64;
    clientRefund: Int as coins;
    reason:       String;
}

message TimeoutClaimed { escrowId: Int as uint64; }

message DisputeRaised {
    escrowId:        Int as uint64;
    raiser:          Address;
    assignedTo:      Address?;
    autoSettleAfter: Int as uint64;
}

message DisputeResolved {
    escrowId:       Int as uint64;
    resolver:       Address;
    clientShareBps: Int as uint16;
}

message DisputeReassigned {
    escrowId:   Int as uint64;
    assignedTo: Address?;
}

message DisputeTimedOut {
    escrowId:       Int as uint64;
    claimedBy:      Address;
    clientShareBps: Int as uint16;
}

message FundsDistributed {
    escrowId:       Int as uint64;
    providerAmount: Int as coins;
    clientAmount:   Int as coins;
    feeAmount:      Int as coins;
}

message SupportAdded   { support: Address; }
message SupportRemoved { support: Address; }

message OwnershipTransferStarted { newOwner: Address; }
message OwnershipTransferred { previousOwner: Address; newOwner: Address; }
message PausedChanged { paused: Bool; }
