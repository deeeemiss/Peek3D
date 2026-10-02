import SwiftUI

/// One open-source dependency whose code ships inside the Peek3D binary,
/// with the full text of its license.
///
/// This list mirrors what is actually compiled into `GLTFKit2.framework`
/// (verified with `nm`/`strings` on the built Release binary — see
/// `LICENSE.md`), not just what Peek3D's own Swift code calls directly.
/// Attribution obligations for permissive licenses (MIT, Apache 2.0,
/// BSD-3-Clause) are triggered by distribution, not by which code paths
/// this app happens to exercise at runtime.
struct OSSLicenseEntry: Identifiable {
    let id: String
    let name: String
    let holder: String
    let license: String
    let text: String
}

enum OSSLicenses {
    static let all: [OSSLicenseEntry] = [
        OSSLicenseEntry(
            id: "gltfkit2",
            name: "GLTFKit2",
            holder: "Warren Moore",
            license: "MIT License",
            text: LicenseTexts.mit(copyright: "Copyright (c) 2021 Warren Moore")
        ),
        OSSLicenseEntry(
            id: "cgltf",
            name: "cgltf",
            holder: "Johannes Kuhlmann",
            license: "MIT License",
            text: LicenseTexts.mit(copyright: "Copyright (c) 2018-2021 Johannes Kuhlmann")
        ),
        OSSLicenseEntry(
            id: "ufbx",
            name: "ufbx",
            holder: "Samuli Raivio",
            license: "MIT License / The Unlicense (dual-licensed)",
            text: LicenseTexts.ufbx
        ),
        OSSLicenseEntry(
            id: "ktx",
            name: "KTX-Software (libktx)",
            holder: "The Khronos Group Inc.",
            license: "Apache License 2.0",
            text: LicenseTexts.apache2(copyright: "Copyright 2010-2024 The Khronos Group Inc.")
        ),
        OSSLicenseEntry(
            id: "basisu",
            name: "Basis Universal",
            holder: "Binomial LLC",
            license: "Apache License 2.0",
            text: LicenseTexts.apache2(copyright: "Copyright 2019-2024 Binomial LLC")
        ),
        OSSLicenseEntry(
            id: "zstd",
            name: "Zstandard",
            holder: "Meta Platforms, Inc. and affiliates",
            license: "BSD 3-Clause License",
            text: LicenseTexts.bsd3(copyright: "Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.")
        ),
    ]
}

/// Canonical, unmodified license texts. Kept as plain string templates
/// (rather than one string per dependency) because MIT/Apache-2.0/BSD-3
/// are fixed boilerplate that only varies by copyright line — spelling
/// each one out separately would risk the texts silently drifting apart.
enum LicenseTexts {
    static func mit(copyright: String) -> String {
        """
        MIT License

        \(copyright)

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """
    }

    static let ufbx = """
    This software is available under 2 licenses -- choose whichever you prefer.
    ------------------------------------------------------------------------------
    ALTERNATIVE A - MIT License
    Copyright (c) 2020 Samuli Raivio
    Permission is hereby granted, free of charge, to any person obtaining a copy of \
    this software and associated documentation files (the "Software"), to deal in \
    the Software without restriction, including without limitation the rights to \
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies \
    of the Software, and to permit persons to whom the Software is furnished to do \
    so, subject to the following conditions:
    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    ------------------------------------------------------------------------------
    ALTERNATIVE B - Public Domain (www.unlicense.org)
    This is free and unencumbered software released into the public domain.
    Anyone is free to copy, modify, publish, use, compile, sell, or distribute this \
    software, either in source code form or as a compiled binary, for any purpose, \
    commercial or non-commercial, and by any means.
    In jurisdictions that recognize copyright laws, the author or authors of this \
    software dedicate any and all copyright interest in the software to the public \
    domain. We make this dedication for the benefit of the public at large and to \
    the detriment of our heirs and successors. We intend this dedication to be an \
    overt act of relinquishment in perpetuity of all present and future rights to \
    this software under copyright law.
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN \
    ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION \
    WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    ------------------------------------------------------------------------------
    """

    static func apache2(copyright: String) -> String {
        """
        Apache License
        Version 2.0, January 2004
        http://www.apache.org/licenses/

        \(copyright)

        TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

        1. Definitions.

        "License" shall mean the terms and conditions for use, reproduction, \
        and distribution as defined by Sections 1 through 9 of this document.

        "Licensor" shall mean the copyright owner or entity authorized by \
        the copyright owner that is granting the License.

        "Legal Entity" shall mean the union of the acting entity and all \
        other entities that control, are controlled by, or are under common \
        control with that entity. For the purposes of this definition, \
        "control" means (i) the power, direct or indirect, to cause the \
        direction or management of such entity, whether by contract or \
        otherwise, or (ii) ownership of fifty percent (50%) or more of the \
        outstanding shares, or (iii) beneficial ownership of such entity.

        "You" (or "Your") shall mean an individual or Legal Entity \
        exercising permissions granted by this License.

        "Source" form shall mean the preferred form for making modifications, \
        including but not limited to software source code, documentation \
        source, and configuration files.

        "Object" form shall mean any form resulting from mechanical \
        transformation or translation of a Source form, including but \
        not limited to compiled object code, generated documentation, \
        and conversions to other media types.

        "Work" shall mean the work of authorship, whether in Source or \
        Object form, made available under the License, as indicated by a \
        copyright notice that is included in or attached to the work \
        (an example is provided in the Appendix below).

        "Derivative Works" shall mean any work, whether in Source or Object \
        form, that is based on (or derived from) the Work and for which the \
        editorial revisions, annotations, elaborations, or other modifications \
        represent, as a whole, an original work of authorship. For the purposes \
        of this License, Derivative Works shall not include works that remain \
        separable from, or merely link (or bind by name) to the interfaces of, \
        the Work and Derivative Works thereof.

        "Contribution" shall mean any work of authorship, including the \
        original version of the Work and any modifications or additions to \
        that Work or Derivative Works thereof, that is intentionally submitted \
        to Licensor for inclusion in the Work by the copyright owner or by an \
        individual or Legal Entity authorized to submit on behalf of the \
        copyright owner. For the purposes of this definition, "submitted" \
        means any form of electronic, verbal, or written communication sent \
        to the Licensor or its representatives, including but not limited to \
        communication on electronic mailing lists, source code control systems, \
        and issue tracking systems that are managed by, or on behalf of, the \
        Licensor for the purpose of discussing and improving the Work, but \
        excluding communication that is conspicuously marked or otherwise \
        designated in writing by the copyright owner as "Not a Contribution."

        "Contributor" shall mean Licensor and any individual or Legal Entity \
        on behalf of whom a Contribution has been received by Licensor and \
        subsequently incorporated within the Work.

        2. Grant of Copyright License. Subject to the terms and conditions of \
        this License, each Contributor hereby grants to You a perpetual, \
        worldwide, non-exclusive, no-charge, royalty-free, irrevocable \
        copyright license to reproduce, prepare Derivative Works of, \
        publicly display, publicly perform, sublicense, and distribute the \
        Work and such Derivative Works in Source or Object form.

        3. Grant of Patent License. Subject to the terms and conditions of \
        this License, each Contributor hereby grants to You a perpetual, \
        worldwide, non-exclusive, no-charge, royalty-free, irrevocable \
        (except as stated in this section) patent license to make, have made, \
        use, offer to sell, sell, import, and otherwise transfer the Work, \
        where such license applies only to those patent claims licensable \
        by such Contributor that are necessarily infringed by their \
        Contribution(s) alone or by combination of their Contribution(s) \
        with the Work to which such Contribution(s) was submitted. If You \
        institute patent litigation against any entity (including a \
        cross-claim or counterclaim in a lawsuit) alleging that the Work \
        or a Contribution incorporated within the Work constitutes direct \
        or contributory patent infringement, then any patent licenses \
        granted to You under this License for that Work shall terminate \
        as of the date such litigation is filed.

        4. Redistribution. You may reproduce and distribute copies of the \
        Work or Derivative Works thereof in any medium, with or without \
        modifications, and in Source or Object form, provided that You \
        meet the following conditions:

        (a) You must give any other recipients of the Work or \
        Derivative Works a copy of this License; and

        (b) You must cause any modified files to carry prominent notices \
        stating that You changed the files; and

        (c) You must retain, in the Source form of any Derivative Works \
        that You distribute, all copyright, patent, trademark, and \
        attribution notices from the Source form of the Work, excluding \
        those notices that do not pertain to any part of the Derivative \
        Works; and

        (d) If the Work includes a "NOTICE" text file as part of its \
        distribution, then any Derivative Works that You distribute must \
        include a readable copy of the attribution notices contained \
        within such NOTICE file, excluding those notices that do not \
        pertain to any part of the Derivative Works, in at least one of \
        the following places: within a NOTICE text file distributed as part \
        of the Derivative Works; within the Source form or documentation, \
        if provided along with the Derivative Works; or, within a display \
        generated by the Derivative Works, if and wherever such third-party \
        notices normally appear. The contents of the NOTICE file are for \
        informational purposes only and do not modify the License. You may \
        add Your own attribution notices within Derivative Works that You \
        distribute, alongside or as an addendum to the NOTICE text from the \
        Work, provided that such additional attribution notices cannot be \
        construed as modifying the License.

        You may add Your own copyright statement to Your modifications and \
        may provide additional or different license terms and conditions \
        for use, reproduction, or distribution of Your modifications, or \
        for any such Derivative Works as a whole, provided Your use, \
        reproduction, and distribution of the Work otherwise complies with \
        the conditions stated in this License.

        5. Submission of Contributions. Unless You explicitly state otherwise, \
        any Contribution intentionally submitted for inclusion in the Work \
        by You to the Licensor shall be under the terms and conditions of \
        this License, without any additional terms or conditions. \
        Notwithstanding the above, nothing herein shall supersede or modify \
        the terms of any separate license agreement you may have executed \
        with Licensor regarding such Contributions.

        6. Trademarks. This License does not grant permission to use the trade \
        names, trademarks, service marks, or product names of the Licensor, \
        except as required for reasonable and customary use in describing the \
        origin of the Work and reproducing the content of the NOTICE file.

        7. Disclaimer of Warranty. Unless required by applicable law or \
        agreed to in writing, Licensor provides the Work (and each \
        Contributor provides its Contributions) on an "AS IS" BASIS, \
        WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or \
        implied, including, without limitation, any warranties or conditions \
        of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A \
        PARTICULAR PURPOSE. You are solely responsible for determining the \
        appropriateness of using or redistributing the Work and assume any \
        risks associated with Your exercise of permissions under this License.

        8. Limitation of Liability. In no event and under no legal theory, \
        whether in tort (including negligence), contract, or otherwise, \
        unless required by applicable law (such as deliberate and grossly \
        negligent acts) or agreed to in writing, shall any Contributor be \
        liable to You for damages, including any direct, indirect, special, \
        incidental, or consequential damages of any character arising as a \
        result of this License or out of the use or inability to use the \
        Work (including but not limited to damages for loss of goodwill, \
        work stoppage, computer failure or malfunction, or any and all \
        other commercial damages or losses), even if such Contributor has \
        been advised of the possibility of such damages.

        9. Accepting Warranty or Additional Liability. While redistributing \
        the Work or Derivative Works thereof, You may choose to offer, and \
        charge a fee for, acceptance of support, warranty, indemnity, or \
        other liability obligations and/or rights consistent with this \
        License. However, in accepting such obligations, You may act only \
        on Your own behalf and on Your sole responsibility, not on behalf \
        of any other Contributor, and only if You agree to indemnify, \
        defend, and hold each Contributor harmless for any liability \
        incurred by, or claims asserted against, such Contributor by reason \
        of your accepting any such warranty or additional liability.

        END OF TERMS AND CONDITIONS
        """
    }

    static func bsd3(copyright: String) -> String {
        """
        BSD License

        \(copyright)

        Redistribution and use in source and binary forms, with or without \
        modification, are permitted provided that the following conditions are met:

        * Redistributions of source code must retain the above copyright notice, \
          this list of conditions and the following disclaimer.

        * Redistributions in binary form must reproduce the above copyright notice, \
          this list of conditions and the following disclaimer in the documentation \
          and/or other materials provided with the distribution.

        * Neither the name of the copyright holder nor the names of its \
          contributors may be used to endorse or promote products derived from \
          this software without specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
        AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
        IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE \
        ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE \
        LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR \
        CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF \
        SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS \
        INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN \
        CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) \
        ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE \
        POSSIBILITY OF SUCH DAMAGE.
        """
    }
}

/// Standalone window opened from the app menu ("Licenze open source…", see
/// `Peek3DApp.swift`). Reuses `WelcomeView`'s dark-only visual tokens
/// (background `Color(white: 0.04)`, white text at scaled opacities, 8/16pt
/// radii, accent blue `Color(red: 0.35, green: 0.68, blue: 1.0)`) rather
/// than the default `List`/`NavigationSplitView` chrome, which would bring
/// in its own light-capable materials this dark-only app doesn't otherwise use.
struct OpenSourceLicensesView: View {
    @State private var selectedID: String = OSSLicenses.all[0].id

    private var selected: OSSLicenseEntry {
        OSSLicenses.all.first(where: { $0.id == selectedID }) ?? OSSLicenses.all[0]
    }

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                Divider().overlay(Color.white.opacity(0.08))
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Only this window's own chrome is localized here — the license
            // texts themselves (MIT/Apache-2.0/BSD-3-Clause boilerplate,
            // LicenseTexts above) stay in English, per this project's own
            // attribution obligations: those are the legally-operative
            // documents, not UI copy, and translating them would risk
            // changing their meaning.
            Text("ossLicenses.title", comment: "Sidebar header of the open-source licenses window")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 4)
            Text("ossLicenses.subtitle", comment: "Sidebar subheading of the open-source licenses window")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(OSSLicenses.all) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private func entryRow(_ entry: OSSLicenseEntry) -> some View {
        let isSelected = entry.id == selectedID
        return Button {
            selectedID = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.75))
                Text(entry.license)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(isSelected ? 0.6 : 0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .background(
            isSelected ? Color.white.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.name)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.35, green: 0.68, blue: 1.0), .white],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("\(selected.license) — \(selected.holder)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                }

                Text(selected.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.08))
                    )
            }
            .padding(24)
        }
    }
}
