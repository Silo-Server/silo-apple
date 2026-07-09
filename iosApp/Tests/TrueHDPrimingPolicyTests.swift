import XCTest
@testable import Silo

final class TrueHDPrimingPolicyTests: XCTestCase {
    func testVODRestartBuffersSelectedAudioWhileVideoGateIsWaiting() {
        XCTAssertTrue(
            LoopbackVODPreGateAudioBufferPolicy.canBuffer(
                isRestart: true,
                isSelectedAudio: true,
                isWaitingForVideoGate: true,
                bufferedPackets: 4,
                bufferedBytes: 4_096,
                packetBytes: 1_024
            )
        )
    }

    func testVODPreGateBufferDoesNotApplyAfterGateOrToOtherStreams() {
        XCTAssertFalse(
            LoopbackVODPreGateAudioBufferPolicy.canBuffer(
                isRestart: true,
                isSelectedAudio: true,
                isWaitingForVideoGate: false,
                bufferedPackets: 0,
                bufferedBytes: 0,
                packetBytes: 1
            )
        )
        XCTAssertFalse(
            LoopbackVODPreGateAudioBufferPolicy.canBuffer(
                isRestart: true,
                isSelectedAudio: false,
                isWaitingForVideoGate: true,
                bufferedPackets: 0,
                bufferedBytes: 0,
                packetBytes: 1
            )
        )
    }

    func testVODPreGateBufferIsBoundedByPacketsAndBytes() {
        XCTAssertFalse(
            LoopbackVODPreGateAudioBufferPolicy.canBuffer(
                isRestart: true,
                isSelectedAudio: true,
                isWaitingForVideoGate: true,
                bufferedPackets: 3,
                bufferedBytes: 3,
                packetBytes: 1,
                maxPackets: 3,
                maxBytes: 10
            )
        )
        XCTAssertFalse(
            LoopbackVODPreGateAudioBufferPolicy.canBuffer(
                isRestart: true,
                isSelectedAudio: true,
                isWaitingForVideoGate: true,
                bufferedPackets: 0,
                bufferedBytes: 9,
                packetBytes: 2,
                maxPackets: 3,
                maxBytes: 10
            )
        )
    }

    func testVODPreGateReplayKeepsPacketOverlappingVideoGate() {
        XCTAssertFalse(
            LoopbackVODPreGateAudioBufferPolicy.shouldDropReplayedPacket(
                dts: 900,
                duration: 200,
                gateDTS: 1_000
            )
        )
        XCTAssertTrue(
            LoopbackVODPreGateAudioBufferPolicy.shouldDropReplayedPacket(
                dts: 800,
                duration: 200,
                gateDTS: 1_000
            )
        )
    }

    func testTailPolicyDropsOldestPacketWhenPacketCapWouldBeExceeded() {
        let dropCount = DVPreVideoAudioTailPolicy.headDropCountBeforeAppending(
            existingByteSizes: [10, 10, 10],
            retainedBytes: 30,
            incomingBytes: 10,
            maxPackets: 3,
            maxBytes: 100
        )

        XCTAssertEqual(dropCount, 1)
    }

    func testTailPolicyDropsOldestPacketsUntilByteCapAllowsIncomingPacket() {
        let dropCount = DVPreVideoAudioTailPolicy.headDropCountBeforeAppending(
            existingByteSizes: [4, 4, 4],
            retainedBytes: 12,
            incomingBytes: 4,
            maxPackets: 10,
            maxBytes: 10
        )

        XCTAssertEqual(dropCount, 2)
    }

    func testTailPolicyRejectsPacketLargerThanByteCap() {
        let dropCount = DVPreVideoAudioTailPolicy.headDropCountBeforeAppending(
            existingByteSizes: [2, 2],
            retainedBytes: 4,
            incomingBytes: 11,
            maxPackets: 10,
            maxBytes: 10
        )

        XCTAssertNil(dropCount)
    }

    func testTrueHDMajorSyncScannerFindsSyncInRetainedBytes() {
        let retainedTail = Data([0x00, 0x11, 0x22, 0xF8, 0x72, 0x6F, 0xBA, 0x33])

        XCTAssertTrue(DVTrueHDMajorSyncScanner.containsMajorSync(retainedTail))
    }
}
