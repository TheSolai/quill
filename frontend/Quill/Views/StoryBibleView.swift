import SwiftUI

/// Story Bible / Codex — the structured lore database the AI references.
/// Surfaces everything from /api/projects/<id>/codex, both the freeform
/// text fields and the structured lists (characters, locations, timeline,
/// relationships, themes, motifs, glossary, voice, plot beats).
struct StoryBibleView: View {
    @ObservedObject var state: AppState
    let bgPrimary: Color
    let bgSecondary: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color

    @State private var localCodex: Codex = Codex()
    @State private var isEditing = false
    @State private var isExtracting = false
    @State private var showFreeform = false  // collapsed by default; structured is more useful

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(border)
            content
        }
        .background(bgPrimary)
        .onAppear {
            Task {
                await state.loadCodex()
                localCodex = state.codex
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed.fill")
                .foregroundColor(accent)
            Text("STORY BIBLE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(accent)
            // Population indicator
            populationPill
            Spacer()
            if isExtracting {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                    Text("extracting…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(textMuted)
                }
            } else {
                Button(action: runExtract) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("/extract")
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Read all chapters and populate the Story Bible")
            }
            if isEditing {
                Button("Cancel") {
                    isEditing = false
                    localCodex = state.codex
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Save") {
                    Task {
                        state.codex = localCodex
                        await state.saveCodex()
                        isEditing = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button(action: { isEditing = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                        Text("Edit")
                    }
                    .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bgSecondary)
    }

    private var populationPill: some View {
        let count = state.codex.populationCount
        return HStack(spacing: 3) {
            Circle()
                .fill(count > 0 ? Color.green : Color.gray)
                .frame(width: 5, height: 5)
            Text("\(count) entries")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(textMuted)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .stroke(border, lineWidth: 1)
        )
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if state.codex.populationCount == 0 && !isEditing {
                    emptyState
                } else {
                    voiceSection
                    charactersSection
                    locationsSection
                    timelineSection
                    relationshipsSection
                    themesMotifsSection
                    glossarySection
                    plotSection
                    freeformSection  // collapsed by default
                }
            }
            .padding(16)
        }
        .background(bgPrimary)
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 36))
                .foregroundColor(textMuted.opacity(0.5))
            Text("Your Story Bible is empty")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(textPrimary)
            Text("Click **/extract** above to read your chapters and have Quill build the Story Bible for you. Or click **Edit** to type it in manually.")
                .font(.system(size: 11))
                .foregroundColor(textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Sections

    private var voiceSection: some View {
        sectionCard(title: "Voice", icon: "speaker.wave.2.fill") {
            VStack(alignment: .leading, spacing: 8) {
                threeFieldRow(
                    label: "Tone",
                    placeholder: "e.g. dark, lyrical, hopeful",
                    value: voiceBinding(\.tone)
                )
                threeFieldRow(
                    label: "POV",
                    placeholder: "third-limited",
                    value: voiceBinding(\.pov)
                )
                threeFieldRow(
                    label: "Tense",
                    placeholder: "past",
                    value: voiceBinding(\.tense)
                )
                if let style = state.codex.style.nonEmpty, !isEditing {
                    Text(style)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textSecondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var charactersSection: some View {
        sectionCard(title: "Characters", icon: "person.2.fill",
                    empty: state.codex.charactersList.isEmpty && !isEditing,
                    emptyText: "No characters extracted yet") {
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    ForEach($localCodex.charactersList) { $c in
                        characterEditorRow(c: $c) { removeCharacter(c.id) }
                    }
                    Button(action: addCharacter) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Add character")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                } else {
                    ForEach(state.codex.charactersList) { c in
                        characterRow(c)
                    }
                }
            }
        }
    }

    private var locationsSection: some View {
        sectionCard(title: "Locations", icon: "mappin.and.ellipse",
                    empty: state.codex.locations.isEmpty && !isEditing,
                    emptyText: "No locations extracted yet") {
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    ForEach($localCodex.locations) { $l in
                        locationEditorRow(l: $l) { removeLocation(l.id) }
                    }
                    Button(action: addLocation) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Add location")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                } else {
                    ForEach(state.codex.locations) { l in
                        locationRow(l)
                    }
                }
            }
        }
    }

    private var timelineSection: some View {
        sectionCard(title: "Timeline", icon: "clock.fill",
                    empty: state.codex.timeline.isEmpty && !isEditing,
                    emptyText: "No timeline events yet") {
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    ForEach($localCodex.timeline) { $t in
                        timelineEditorRow(t: $t) { removeTimelineEvent(t.id) }
                    }
                    Button(action: addTimelineEvent) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Add event")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                } else {
                    let sorted = state.codex.timeline.sorted { $0.order < $1.order }
                    ForEach(sorted) { t in
                        timelineRow(t)
                    }
                }
            }
        }
    }

    private var relationshipsSection: some View {
        sectionCard(title: "Relationships", icon: "link",
                    empty: state.codex.relationships.isEmpty && !isEditing,
                    emptyText: "No relationships extracted yet") {
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    ForEach($localCodex.relationships) { $r in
                        relationshipEditorRow(r: $r) { removeRelationship(r.id) }
                    }
                    Button(action: addRelationship) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Add relationship")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                } else {
                    ForEach(state.codex.relationships) { r in
                        relationshipRow(r)
                    }
                }
            }
        }
    }

    private var themesMotifsSection: some View {
        sectionCard(title: "Themes & Motifs", icon: "tag.fill",
                    empty: state.codex.themesList.isEmpty && state.codex.motifs.isEmpty && !isEditing,
                    emptyText: "No themes or motifs yet") {
            VStack(alignment: .leading, spacing: 12) {
                tagSection(title: "Themes", items: state.codex.themesList, accent: accent)
                tagSection(title: "Motifs (recurring imagery)", items: state.codex.motifs, accent: .orange)
            }
        }
    }

    private var glossarySection: some View {
        sectionCard(title: "Glossary", icon: "book",
                    empty: state.codex.glossary.isEmpty && !isEditing,
                    emptyText: "No glossary entries yet") {
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    ForEach($localCodex.glossary) { $g in
                        HStack(spacing: 6) {
                            TextField("Term", text: $g.term)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 120)
                            TextField("Definition", text: $g.definition)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Button(action: { removeGlossary(g.id) }) {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button(action: addGlossary) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Add term")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                } else {
                    ForEach(state.codex.glossary) { g in
                        HStack(alignment: .top, spacing: 6) {
                            Text(g.term)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(accent)
                                .frame(width: 120, alignment: .leading)
                            Text(g.definition)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var plotSection: some View {
        sectionCard(title: "Plot", icon: "list.bullet.rectangle",
                    empty: state.codex.incitingIncident.isEmpty
                       && state.codex.climax.isEmpty
                       && state.codex.resolution.isEmpty
                       && !isEditing,
                    emptyText: "No plot beats yet") {
            VStack(alignment: .leading, spacing: 12) {
                plotField(label: "Inciting incident", icon: "bolt.fill",
                          placeholder: "The event that kicks off the main plot",
                          value: plotBinding(\.incitingIncident))
                plotField(label: "Climax", icon: "flame.fill",
                          placeholder: "Where the conflict peaks",
                          value: plotBinding(\.climax))
                plotField(label: "Resolution", icon: "checkmark.seal.fill",
                          placeholder: "How the story resolves",
                          value: plotBinding(\.resolution))
            }
        }
    }

    private var freeformSection: some View {
        DisclosureGroup(isExpanded: $showFreeform) {
            VStack(alignment: .leading, spacing: 12) {
                freeformField(title: "Free-form characters", icon: "person.text.rectangle",
                              value: binding(for: \.characters),
                              placeholder: "Anything else about your characters not captured above")
                freeformField(title: "World & setting", icon: "globe",
                              value: binding(for: \.world),
                              placeholder: "The setting of your story")
                freeformField(title: "Summary", icon: "doc.text.fill",
                              value: binding(for: \.summary),
                              placeholder: "A short plot summary")
                freeformField(title: "Style guide", icon: "paintbrush.fill",
                              value: binding(for: \.style),
                              placeholder: "Voice, sentence rhythm, what to avoid…")
                freeformField(title: "Plot outline", icon: "list.bullet.rectangle",
                              value: binding(for: \.plot),
                              placeholder: "Act-by-act outline")
                freeformField(title: "Themes (free-form)", icon: "tag.fill",
                              value: binding(for: \.themes),
                              placeholder: "Free-form themes notes")
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 11))
                    .foregroundColor(textMuted)
                Text("FREE-FORM FIELDS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                Text("(legacy — use structured fields above)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(textMuted.opacity(0.7))
            }
        }
        .padding(12)
        .background(bgSecondary)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(border, lineWidth: 1)
        )
    }

    // MARK: - Reusable section card

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        empty: Bool = false,
        emptyText: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(accent)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
            }
            if empty, let msg = emptyText {
                Text(msg)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
                    .italic()
            } else {
                content()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bgSecondary)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(border, lineWidth: 1)
        )
    }

    // MARK: - Row renderers

    private func characterRow(_ c: StoryCharacter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(c.name.isEmpty ? "Unnamed" : c.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(textPrimary)
                if !c.role.isEmpty {
                    Text(c.role)
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.2))
                        .foregroundColor(accent)
                        .cornerRadius(3)
                }
            }
            if !c.description.isEmpty {
                Text(c.description)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textSecondary)
            }
            if !c.goal.isEmpty || !c.arc.isEmpty {
                HStack(spacing: 12) {
                    if !c.goal.isEmpty {
                        Label(c.goal, systemImage: "target")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textMuted)
                            .lineLimit(1)
                    }
                    if !c.arc.isEmpty {
                        Label(c.arc, systemImage: "arrow.up.right")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(bgPrimary.opacity(0.5))
        .cornerRadius(4)
    }

    private func characterEditorRow(c: Binding<StoryCharacter>, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Name", text: c.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, weight: .semibold))
                TextField("role (protagonist, etc.)", text: c.role)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .frame(width: 160)
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            TextField("Description", text: c.description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1...3)
            HStack(spacing: 6) {
                TextField("Goal", text: c.goal)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                TextField("Arc", text: c.arc)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
            }
        }
        .padding(8)
        .background(bgPrimary.opacity(0.5))
        .cornerRadius(4)
    }

    private func locationRow(_ l: StoryLocation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l.name.isEmpty ? "Unnamed" : l.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(textPrimary)
            if !l.description.isEmpty {
                Text(l.description)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textSecondary)
            }
            if !l.significance.isEmpty {
                Text("Why it matters: \(l.significance)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
                    .italic()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(bgPrimary.opacity(0.5))
        .cornerRadius(4)
    }

    private func locationEditorRow(l: Binding<StoryLocation>, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Name", text: l.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, weight: .semibold))
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            TextField("Description", text: l.description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1...3)
            TextField("Why it matters", text: l.significance)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
        }
        .padding(8)
        .background(bgPrimary.opacity(0.5))
        .cornerRadius(4)
    }

    private func timelineRow(_ t: StoryTimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(t.when)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(accent)
                .frame(width: 140, alignment: .leading)
            Text(t.what)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textSecondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(bgPrimary.opacity(0.5))
        .cornerRadius(4)
    }

    private func timelineEditorRow(t: Binding<StoryTimelineEvent>, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            TextField("Order #", value: t.order, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 50)
            TextField("When (Day 1, Year X, etc.)", text: t.when)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 180)
            TextField("What happens", text: t.what)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(bgPrimary.opacity(0.5))
        .cornerRadius(4)
    }

    private func relationshipRow(_ r: StoryRelationship) -> some View {
        HStack(spacing: 6) {
            Text(r.from)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundColor(textMuted)
            Text(r.to)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)
            if !r.type.isEmpty {
                Text("(\(r.type))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
            }
            if !r.description.isEmpty {
                Text("— \(r.description)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(bgPrimary.opacity(0.5))
        .cornerRadius(4)
    }

    private func relationshipEditorRow(r: Binding<StoryRelationship>, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("From (character)", text: r.from)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                TextField("→", text: .constant("→"))
                    .disabled(true)
                    .frame(width: 24)
                TextField("To (character)", text: r.to)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                TextField("type (sister, rival, etc.)", text: r.type)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 140)
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            TextField("Description (optional)", text: r.description)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
        }
        .padding(8)
        .background(bgPrimary.opacity(0.5))
        .cornerRadius(4)
    }

    private func tagSection(title: String, items: [String], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(textMuted)
            if items.isEmpty {
                Text("None yet")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
                    .italic()
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(accent.opacity(0.15))
                            .cornerRadius(8)
                    }
                }
            }
        }
    }

    private func threeFieldRow(label: String, placeholder: String, value: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(textMuted)
                .frame(width: 50, alignment: .trailing)
            if isEditing {
                TextField(placeholder, text: value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            } else {
                Text(value.wrappedValue.isEmpty ? "—" : value.wrappedValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(value.wrappedValue.isEmpty ? textMuted : textPrimary)
            }
        }
    }

    private func plotField(label: String, icon: String, placeholder: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(accent)
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(textPrimary)
            }
            if isEditing {
                TextEditor(text: value)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 50, maxHeight: 100)
                    .background(bgPrimary)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(border, lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if value.wrappedValue.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(textMuted)
                                .italic()
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                Text(value.wrappedValue.isEmpty ? "Not set" : value.wrappedValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(value.wrappedValue.isEmpty ? textMuted : textSecondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgPrimary)
                    .cornerRadius(4)
                    .textSelection(.enabled)
            }
        }
    }

    private func freeformField(title: String, icon: String, value: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(textMuted)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(textMuted)
            }
            if isEditing {
                TextEditor(text: value)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 120)
                    .background(bgPrimary)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(border, lineWidth: 1)
                    )
            } else if value.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
                    .italic()
            } else {
                Text(value.wrappedValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private func runExtract() {
        guard !isExtracting else { return }
        isExtracting = true
        Task {
            // Use the chat endpoint with the /extract slash command. The
            // backend will read all chapters and update the codex.
            let prompt = "/extract"
            await state.sendMessage(prompt, mode: .short, chapter: "", outline: "", style: "")
            // The chat onDone handler may or may not refresh the codex
            // automatically; force a reload.
            await state.loadCodex()
            localCodex = state.codex
            isExtracting = false
        }
    }

    private func voiceBinding(_ keyPath: WritableKeyPath<Codex, String>) -> Binding<String> {
        isEditing
            ? Binding(
                get: { localCodex[keyPath: keyPath] },
                set: { localCodex[keyPath: keyPath] = $0 }
              )
            : Binding(
                get: { state.codex[keyPath: keyPath] },
                set: { _ in }
              )
    }

    private func plotBinding(_ keyPath: WritableKeyPath<Codex, String>) -> Binding<String> {
        voiceBinding(keyPath)
    }

    private func binding(for keyPath: WritableKeyPath<Codex, String>) -> Binding<String> {
        voiceBinding(keyPath)
    }

    // MARK: - Editor add/remove handlers

    private func addCharacter() {
        localCodex.charactersList.append(StoryCharacter())
    }
    private func removeCharacter(_ id: UUID) {
        localCodex.charactersList.removeAll { $0.id == id }
    }
    private func addLocation() {
        localCodex.locations.append(StoryLocation())
    }
    private func removeLocation(_ id: UUID) {
        localCodex.locations.removeAll { $0.id == id }
    }
    private func addTimelineEvent() {
        let next = (localCodex.timeline.map { $0.order }.max() ?? -1) + 1
        localCodex.timeline.append(StoryTimelineEvent(order: next))
    }
    private func removeTimelineEvent(_ id: UUID) {
        localCodex.timeline.removeAll { $0.id == id }
    }
    private func addRelationship() {
        localCodex.relationships.append(StoryRelationship())
    }
    private func removeRelationship(_ id: UUID) {
        localCodex.relationships.removeAll { $0.id == id }
    }
    private func addGlossary() {
        localCodex.glossary.append(StoryGlossaryEntry())
    }
    private func removeGlossary(_ id: UUID) {
        localCodex.glossary.removeAll { $0.id == id }
    }
}

// MARK: - FlowLayout (lightweight wrap layout for tags)
// Apple's SwiftUI has `Layout` protocol (macOS 13+). Use it to make
// the tag chips wrap naturally without manual math.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x,
                      height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        let maxWidth = bounds.width
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - String helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}