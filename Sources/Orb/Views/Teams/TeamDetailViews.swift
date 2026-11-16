import SwiftUI

struct TeamProgressCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let team: OrbTeam

    var body: some View {
        let progress = team.mission.progress
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Progresso da missão")
                    .font(Typography.label.weight(.medium))
                    .foregroundStyle(Palette.faint)
                Spacer(minLength: 8)
                Text("\(progress.stagesDone) de \(progress.totalStages) etapas · \(progress.criteriaVerified) de \(progress.totalCriteria) critérios")
                    .font(Typography.small)
                    .foregroundStyle(Palette.secondary)
                    .contentTransition(.numericText())
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.chipFill)
                    Capsule()
                        .fill(team.status == .completed ? Palette.ok : Palette.accent)
                        .frame(width: max(0, proxy.size.width * progress.fraction))
                        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: progress.fraction)
                }
            }
            .frame(height: 5)

            if !team.mission.stages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(team.mission.stages) { stage in
                        MissionStageRow(stage: stage,
                                        ownerName: stage.ownerMemberID.flatMap { team.member(id: $0)?.name },
                                        reviewerName: stage.reviewerMemberID.flatMap { team.member(id: $0)?.name },
                                        reduceMotion: reduceMotion)
                    }
                }
            }

            if !team.mission.criteria.isEmpty {
                Divider().overlay(Palette.line)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Critérios de pronto")
                        .font(Typography.small.weight(.medium))
                        .foregroundStyle(Palette.faint)
                    ForEach(team.mission.criteria) { criterion in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: criterion.isVerified ? "checkmark.seal.fill" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(criterion.isVerified ? Palette.ok : Palette.faint)
                                .transition(.adapted(.mark, reduceMotion: reduceMotion))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(criterion.description)
                                    .font(Typography.label)
                                    .foregroundStyle(criterion.isVerified ? Palette.ink : Palette.secondary)
                                if !criterion.lastEvidence.isEmpty {
                                    Text(criterion.lastEvidence)
                                        .font(Typography.codeSmall)
                                        .foregroundStyle(Palette.faint)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(criterion.lastEvidence)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MissionStageRow: View {
    let stage: MissionStage
    let ownerName: String?
    let reviewerName: String?
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: stage.isDone ? "checkmark.circle.fill" : stage.blockerNote.isEmpty ? "circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(stage.isDone ? Palette.ok : stage.blockerNote.isEmpty ? Palette.faint : Palette.warn)
                .transition(.adapted(.mark, reduceMotion: reduceMotion))
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.title)
                    .font(Typography.text)
                    .foregroundStyle(stage.isDone ? Palette.ink : Palette.secondary)
                let details = [ownerName.map { "Execução: \($0)" }, reviewerName.map { "Revisão: \($0)" }].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(Typography.small)
                        .foregroundStyle(Palette.faint)
                }
            }
            Spacer(minLength: 4)
            if stage.isDone {
                Text("Concluída")
                    .font(Typography.small)
                    .foregroundStyle(Palette.ok)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TeamPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(Typography.small.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
