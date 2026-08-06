import EvieCore
import SwiftUI

struct QuickTextEntryView: View {
  @Binding var text: String
  var state: EvieVisualState = .ready
  var waveformSamples: [CGFloat] = []
  var isAnimating = true
  /// While true the send button is a stop button, because the thing you most
  /// want to do to a running answer is end it.
  var isProcessing = false
  var onSubmit: () -> Void
  var onCancel: () -> Void
  var onStop: (() -> Void)? = nil
  var onActivateVoice: (() -> Void)? = nil
  var onBrowseForFiles: (() -> Void)? = nil
  /// Commands worth offering for what has been typed. Empty almost always, which
  /// is the point.
  var commandSuggestions: [EvieCommand] = []
  var highlightedCommand = 0
  var onMoveCommandHighlight: ((Int) -> Void)? = nil
  var onCompleteCommand: (() -> Void)? = nil
  var onDismissCommands: (() -> Void)? = nil

  var attachments: [EvieAttachmentSlot] = []
  var onRemoveAttachment: ((UUID) -> Void)? = nil

  private var isShowingCommands: Bool {
    !commandSuggestions.isEmpty
  }

  @FocusState private var isFocused: Bool

  private var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      commandMenu
      attachmentChips
      field
    }
  }

  /// The files waiting to go with the next message.
  ///
  /// Beside the field rather than in the answer list, which is where they used
  /// to appear — as cards, indistinguishable from something already asked and
  /// answered. A chip here says the opposite: this is attached, not sent, and
  /// here is the cross that takes it back.
  @ViewBuilder
  private var attachmentChips: some View {
    if !attachments.isEmpty {
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          ForEach(attachments) { slot in
            attachmentChip(slot)
          }
        }
        .padding(.horizontal, 2)
      }
      .scrollIndicators(.never)
      .frame(maxHeight: 42)
    }
  }

  private func attachmentChip(_ slot: EvieAttachmentSlot) -> some View {
    HStack(spacing: 6) {
      if let picture = slot.thumbnail {
        Image(nsImage: picture)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 26, height: 26)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          // Dimmed while it is still being read, so the chip shows both what was
          // attached and that it is not finished.
          .opacity(slot.isPreparing ? 0.45 : 1)
          .overlay {
            if slot.isPreparing {
              EvieThinkingIndicator(tint: .white)
            }
          }
      } else if slot.isPreparing {
        EvieThinkingIndicator(tint: .secondary)
      } else if slot.failure != nil {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.orange)
      } else {
        Image(systemName: "paperclip")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }

      Text(slot.name)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 180, alignment: .leading)

      Button {
        onRemoveAttachment?(slot.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .frame(width: 14, height: 14)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Tirar \(slot.name)")
    }
    .padding(.leading, slot.thumbnail == nil ? 9 : 5)
    .padding(.trailing, 6)
    .padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(
      Capsule().strokeBorder(
        slot.failure == nil ? .white.opacity(0.10) : .orange.opacity(0.45),
        lineWidth: 0.75
      )
    )
    .help(slot.failure ?? slot.name)
  }

  /// The commands, above the field because the field is at the bottom of the
  /// screen and a menu below it would be off the edge.
  @ViewBuilder
  private var commandMenu: some View {
    if isShowingCommands {
      GlassSurface(
        cornerRadius: 18,
        material: .hudWindow,
        contentPadding: EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7),
        tint: EvieVoiceTint.idle
      ) {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(Array(commandSuggestions.enumerated()), id: \.element.id) { index, command in
            commandRow(command, isHighlighted: index == highlightedCommand)
          }
        }
      }
      .transition(.opacity)
    }
  }

  private func commandRow(_ command: EvieCommand, isHighlighted: Bool) -> some View {
    Button {
      onMoveCommandHighlight?(0)
      onCompleteCommand?()
    } label: {
      HStack(spacing: 8) {
        Text(command.name)
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
        Text(command.argumentHint)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.tertiary)
        Text(command.summary)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 6)
        // Said here rather than discovered by waiting four minutes.
        if let cost = command.cost {
          Text(cost)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(.white.opacity(isHighlighted ? 0.10 : 0))
      )
    }
    .buttonStyle(.plain)
  }

  private var field: some View {
    GlassSurface(
      cornerRadius: 24,
      material: .hudWindow,
      contentPadding: EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 10),
      tint: state.tint
    ) {
      HStack(spacing: 11) {
        EvieMarkView(
          state: state,
          waveformSamples: waveformSamples,
          diameter: 30,
          isAnimating: isAnimating,
          onActivate: onActivateVoice
        )

        TextField("Pergunte à Evie…", text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.system(size: 14, weight: .medium))
          .lineLimit(1...3)
          .focused($isFocused)
          // Return completes the command when the menu is open, and sends when
          // it is not. Sending "/pl" would run nothing and lose what was typed.
          .onSubmit {
            if isShowingCommands {
              onCompleteCommand?()
            } else {
              onSubmit()
            }
          }
          .onKeyPress(.upArrow) {
            guard isShowingCommands else { return .ignored }
            onMoveCommandHighlight?(-1)
            return .handled
          }
          .onKeyPress(.downArrow) {
            guard isShowingCommands else { return .ignored }
            onMoveCommandHighlight?(1)
            return .handled
          }
          .onKeyPress(.tab) {
            guard isShowingCommands else { return .ignored }
            onCompleteCommand?()
            return .handled
          }
          .accessibilityLabel("Comando para Evie")

        if let onBrowseForFiles {
          EvieGlowButton(
            systemImage: "paperclip",
            label: "Anexar uma imagem ou PDF — ou solte o arquivo aqui",
            tint: EvieVoiceTint.idle,
            diameter: 25,
            glyphSize: 11,
            action: onBrowseForFiles
          )
          .frame(width: 25, height: 25)
        }

        trailingButton
      }
    }
    .onAppear {
      isFocused = true
    }
    // Escape closes the menu first and Evie second, so dismissing a suggestion
    // list does not also throw away the question being written.
    .onExitCommand {
      if isShowingCommands {
        onDismissCommands?()
      } else {
        onCancel()
      }
    }
  }

  @ViewBuilder
  private var trailingButton: some View {
    if isProcessing, let onStop {
      EvieGlowButton(
        systemImage: "stop.fill",
        label: "Parar a resposta",
        tint: .red,
        style: .filled,
        diameter: 27,
        glyphSize: 9,
        action: onStop
      )
      .frame(width: 27, height: 27)
      .transition(.scale.combined(with: .opacity))
    } else {
      EvieGlowButton(
        systemImage: "arrow.up",
        label: "Enviar",
        tint: EvieVoiceTint.idle,
        style: .filled,
        diameter: 27,
        glyphSize: 10,
        isEnabled: !isEmpty,
        action: onSubmit
      )
      .frame(width: 27, height: 27)
      .transition(.scale.combined(with: .opacity))
    }
  }
}
