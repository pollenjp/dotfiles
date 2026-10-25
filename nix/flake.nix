# dotfiles の flake の入口。登録簿 (型と sandbox) の homeConfigurations と、ローカル flake が呼ぶ lib (mkHome・
# privateHosts・前の雛形が呼ぶ hostsWith)・checks・packages・apps・formatter・devShells を出す。
{
  description = "pollenjp dotfiles managed by Nix home-manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      # nixpkgs と home-manager のリリース不一致は home-manager の最頻破壊要因なので
      # 必ず follows で揃える
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nixpkgs の猶予の一部 (nixpkgs から) の例外 (release-age.nix の exceptions.fromNixpkgs) の package を取る
    # nixpkgs (ADR 032)。pin は flake-lock-age.sh が決める: 効いている項目があれば、その最も新しい date の日の
    # 終わりまでの公開、無ければ nixpkgs と同じ revision (取ってくるものを増やさない)。lib/release-age.nix は、
    # 消し時を過ぎていない項目があるときだけこれを読む。
    nixpkgs-exceptions.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      # x86_64-darwin (Intel Mac) は含めない。
      # nixpkgs 26.11 でサポートが打ち切られており、評価時点で
      # "Nixpkgs 26.11 has dropped support for x86_64-darwin." で落ちる。
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;

      # nixpkgs の猶予の例外 (release-age.nix) を、system ごとの overlay と消し時の警告にしたもの (ADR 032)。
      # mkHome が home の pkgs に当てる。
      releaseAge = import ./lib/release-age.nix { inherit lib inputs; };
      mkHome = import ./lib/mk-home.nix { inherit inputs releaseAge; };

      # 登録簿 (hosts/default.nix) を、全ホスト共通の追加 module を挟んで組み立てる。
      #
      # 本体は空で呼ぶ (homeConfigurations = hostsWith [ ])。前の雛形 (ADR 007〜026) のローカル flake
      # (~/dotfiles/flake.nix) は、「このマシンだけの設定」(local) を **登録簿のホストにも** 当てるために
      #
      #   homeConfigurations = dotfiles.lib.hostsWith [ local ] // { ... };
      #
      # と呼ぶ。今の雛形は local を持たず、dotfiles.homeConfigurations を重ねるだけ (ADR 027) だが、まだ移して
      # いない PC が評価できるように残す (全 PC が今の雛形へ移ったら消せる)。mkHome の modules に前置するので、
      # 登録簿側の定義と同じ優先度になる。同じ option を両方が定義したら "conflicting definition values" で落ちる。
      hostsWith =
        extraModules:
        import ./hosts {
          mkHome = args: mkHome (args // { modules = extraModules ++ (args.modules or [ ]); });
        };

      # dotfiles-private の nix/ (ローカル flake の path: の入力。flake = false) の hosts/*.nix から、
      # 登録した PC のホストを組み立てる (ADR 026)。本体は dotfiles-private を input に持たないので
      # 自分では呼ばず、ローカル flake の雛形が
      #
      #   homeConfigurations = dotfiles.homeConfigurations // dotfiles.lib.privateHosts dotfiles-private // { ... };
      #
      # と呼ぶ。素の mkHome で組む (ファイルがその PC の値の全部を持つ。前の雛形の local も当たらない)。
      # dotfiles-private の nix/shared/*.nix の module は、登録した全ホストの modules の前に足す (ADR 030)。
      privateHosts = import ./lib/private-hosts.nix { inherit lib mkHome; };
    in
    {
      homeConfigurations = hostsWith [ ];

      # 登録簿に載せないマシン用の入口。
      #
      # flake は git の**追跡済みファイル**しか見ないので、リポジトリ内に
      # gitignore したホスト定義を置いても評価されない。代わりにリポジトリの外へ
      # 自分用の flake を置き、そこからこれを呼ぶ:
      #
      #   inputs.dotfiles.url = "path:<本体>/nix";
      #   outputs = { dotfiles, ... }: {
      #     homeConfigurations = dotfiles.homeConfigurations // {
      #       tmp = dotfiles.lib.mkHome { username = "…"; system = "x86_64-linux"; claude.devTracker.enable = true; };
      #     };
      #   };
      #
      # 詳細は README 「登録簿に載せずにマシンを足す」を参照 (雛形は scripts/setup-local-flake.sh)。
      # privateHosts は dotfiles-private に登録したホストを読む入口 (README「dotfiles-private に登録したホスト」)。
      # hostsWith は前の雛形が呼ぶので残している (上)。
      lib = { inherit mkHome hostsWith privateHosts; };

      # `nix flake check` は homeConfigurations を評価しない (well-known output ではない)。
      # activationPackage を checks へ再エクスポートして初めて検証対象になる。
      # 各 system には、その system 向けの設定だけを載せる。
      #
      # home 以外に、nix/pkgs/ の道具の unittest も載せる (Linux だけ)。トレーサの BPF と
      # systemd の unit は root とカーネルが要るので、ここで確かめるのは純粋な部分
      # (記録の組み立て・整形・Windows と Linux の対の取り方) だけ (ADR 012)。
      #
      # nix/tests/ のテストも載せる。何を確かめるかは各テストの先頭の「## 確かめること」にだけ書き、
      # ここには写さない (README の「テスト」)。
      #   <名前>.test.sh   bash・jq・git だけのサンドボックスで、確かめる script を渡して流す
      #                    (scriptTest。Linux だけ。unittest と揃える)。ほかの道具が要るもの・script の
      #                    ほかに渡すものがあるものは、その check の上に理由を書いて組む
      #   <名前>.test.mjs  node で流す (Linux だけ)
      #   <名前>.nix       home の設定が作るもの。評価時に assert するので全 system (ビルドして
      #                    確かめる項目は、その system のランナーだけ)
      #
      # pjp-google-ime (ADR 015) の unittest と bootstrap-windows-google-ime.test.sh は、protobuf の入った
      # python と記述子 (Mozc の .proto から作る) が要るので、unittest / scriptTest ではなく専用に組む。
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          googleIme = pkgs.callPackage ./pkgs/pjp-google-ime { };
          unittest =
            name:
            pkgs.runCommand "${name}-unittest" { nativeBuildInputs = [ pkgs.python3 ]; } ''
              cd ${./pkgs + "/${name}"}
              PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -v -p 'test_*.py'
              touch $out
            '';
          scriptTest =
            name: target:
            pkgs.runCommand "${name}-test"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.git
                ];
              }
              ''
                bash ${./tests + "/${name}.test.sh"} ${target}
                touch $out
              '';
        in
        lib.mapAttrs' (name: cfg: lib.nameValuePair "home-${name}" cfg.activationPackage) (
          lib.filterAttrs (_: cfg: cfg.pkgs.stdenv.hostPlatform.system == system) self.homeConfigurations
        )
        # 登録簿は型と sandbox だけ (実機は dotfiles-private。ADR 027) なので、WSL・1Password・windowsFiles・exeExecTrace を
        # 入れた作り物のホストを build する (前は登録簿の実機が受け持っていた。ADR 012)。homeConfigurations には出さない
        # (setup の一覧に出さない・--host で選ばせない)。macOS のランナーで x86_64-linux を build しないよう、
        # x86_64-linux の checks にだけ置く
        // lib.optionalAttrs (system == "x86_64-linux") {
          home-wsl-example =
            (mkHome {
              username = "user";
              system = "x86_64-linux";
              wsl = {
                enable = true;
                windowsUserName = "user";
                windowsFiles.enable = true;
                exeExecTrace.enable = true;
              };
              onePassword.enable = true;
            }).activationPackage;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          pjp-exe-exec-trace-unittest = unittest "pjp-exe-exec-trace";
          pjp-who-is-asking-unittest = unittest "pjp-who-is-asking";
          bootstrap-claude-env-test = scriptTest "bootstrap-claude-env" ./scripts/bootstrap-claude-env.sh;
          bootstrap-claude-footer-links-test = scriptTest "bootstrap-claude-footer-links" ./scripts/bootstrap-claude-footer-links.sh;
          # Claude Code は footer-links.json の正規表現を JavaScript の RegExp で読むので、
          # 同じ RegExp で確かめられる node で流す
          claude-footer-links-test =
            pkgs.runCommand "claude-footer-links-test" { nativeBuildInputs = [ pkgs.nodejs ]; }
              ''
                node ${./tests/claude-footer-links.test.mjs} ${./files/claude/footer-links.json}
                touch $out
              '';
          setup-post-notes-test = scriptTest "setup-post-notes" ./scripts;
          verify-test = scriptTest "verify" ./scripts/verify.sh;
          # flake.lock・flake.nix・設定 (release-age.nix) を本物の nix eval で読むので、nix を足して流す
          # (store は使わない。テストの nix の包みが --store dummy:// を付ける)
          flake-lock-age-test = pkgs.runCommand "flake-lock-age-test" { nativeBuildInputs = [ pkgs.nix ]; } ''
            bash ${./tests/flake-lock-age.test.sh} ${./scripts/flake-lock-age.sh}
            touch $out
          '';
          # script 1 本ではなく scripts/ を丸ごと渡す (warn() を持つ script を全部見る)
          warn-helpers-test = scriptTest "warn-helpers" ./scripts;
          # これも scripts/ を丸ごと渡す (git_github() を持つ script を全部見る)
          git-github-helpers-test = scriptTest "git-github-helpers" ./scripts;
          bootstrap-windows-powershell-profile-test = scriptTest "bootstrap-windows-powershell-profile" ./scripts/bootstrap-windows-powershell-profile.sh;
          bootstrap-windows-openssh-test = scriptTest "bootstrap-windows-openssh" ./scripts/bootstrap-windows-openssh.sh;
          check-winget-version-test = scriptTest "check-winget-version" ./scripts/check-winget-version.sh;
          check-test-headers-test = scriptTest "check-test-headers" ./scripts/check-test-headers.sh;
          # scripts/ と、前の雛形 (ADR 026 の版) の heredoc の原文 (fixtures/local-flake-migrate) を渡す (今の雛形へ移すケース)
          local-flake-migrate-test =
            pkgs.runCommand "local-flake-migrate-test"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.git
                ];
              }
              ''
                bash ${./tests/local-flake-migrate.test.sh} ${./scripts} ${./tests/fixtures/local-flake-migrate}
                touch $out
              '';
          # scripts/ を丸ごと渡す (private_dir() を持つ bootstrap-*.sh と本文を比べる)
          private-host-test = scriptTest "private-host" ./scripts;
          # setup.sh と、その隣の private-host.sh を使う
          setup-host-test = scriptTest "setup-host" ./scripts;
          # 雛形の tmp の例 (fixtures/local-flake-tmp/tmp.nix) も渡し、雛形の本文と同じかを見る (評価は local-flake-tmp-state)
          setup-local-flake-test =
            pkgs.runCommand "setup-local-flake-test"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.git
                ];
              }
              ''
                bash ${./tests/setup-local-flake.test.sh} ${./scripts} ${./tests/fixtures/local-flake-tmp/tmp.nix}
                touch $out
              '';
          # script と一緒に読む cloud の冒頭・skip の一覧 (scripts/claude-cloud/ を丸ごと) と、本物の共通の CLAUDE.md・
          # hook・skill (files/claude/) を渡す。テストが使い捨ての dotfiles の checkout に写して流す
          bootstrap-claude-cloud-test =
            pkgs.runCommand "bootstrap-claude-cloud-test" { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                bash ${./tests/bootstrap-claude-cloud.test.sh} ${./scripts/claude-cloud} ${./files/claude}
                touch $out
              '';
          # check-test-grep-q.sh は shfmt の構文木を jq で読むので、shfmt を足して流す
          check-test-grep-q-test =
            pkgs.runCommand "check-test-grep-q-test"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.shfmt
                ];
              }
              ''
                bash ${./tests/check-test-grep-q.test.sh} ${./scripts/check-test-grep-q.sh}
                touch $out
              '';
          # check-claude-frontmatter.sh は frontmatter を yq (mikefarah/yq) で YAML として読むので、yq-go を足して流す
          check-claude-frontmatter-test =
            pkgs.runCommand "check-claude-frontmatter-test" { nativeBuildInputs = [ pkgs.yq-go ]; }
              ''
                bash ${./tests/check-claude-frontmatter.test.sh} ${./scripts/check-claude-frontmatter.sh}
                touch $out
              '';
          bootstrap-windows-herdr-test = scriptTest "bootstrap-windows-herdr" ./scripts/bootstrap-windows-herdr.sh;
          video-offer-nudge-test = scriptTest "video-offer-nudge" ./files/claude/hooks/video-offer-nudge.sh;
          run-through-nudge-test = scriptTest "run-through-nudge" ./files/claude/hooks/run-through-nudge.sh;
          ssh-agent-notice-test = scriptTest "ssh-agent-notice" ./files/claude/hooks/ssh-agent-notice.sh;
          xref-guard-test = scriptTest "xref-guard" ./files/claude/hooks/xref-guard.sh;
          docs-guard-test = scriptTest "docs-guard" ./files/claude/hooks/docs-guard.sh;
          bootstrap-claude-hook-test = scriptTest "bootstrap-claude-hook" ./scripts/bootstrap-claude-hook.sh;
          pjp-google-ime-unittest =
            pkgs.runCommand "pjp-google-ime-unittest"
              {
                nativeBuildInputs = [ googleIme.python ];
                PJP_GOOGLE_IME_DESCRIPTORS = googleIme.descriptors;
              }
              ''
                cd ${./pkgs/pjp-google-ime}
                PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -v -p 'test_*.py'
                touch $out
              '';
          # 偽の repo と dotfiles-private を git の checkout にし、build では作れない形の辞書
          # (単語登録で足した語など) を protobuf の入った python で組む
          bootstrap-windows-google-ime-test =
            pkgs.runCommand "bootstrap-windows-google-ime-test"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.git
                  googleIme
                  googleIme.python
                ];
                PJP_GOOGLE_IME_DESCRIPTORS = googleIme.descriptors;
              }
              ''
                bash ${./tests/bootstrap-windows-google-ime.test.sh} ${./scripts/bootstrap-windows-google-ime.sh}
                touch $out
              '';
          bootstrap-dotfiles-private-test = scriptTest "bootstrap-dotfiles-private" ./scripts/bootstrap-dotfiles-private.sh;
          bootstrap-cc-pages-test = scriptTest "bootstrap-cc-pages" ./scripts/bootstrap-cc-pages.sh;
          bootstrap-claude-skills-test = scriptTest "bootstrap-claude-skills" ./scripts/bootstrap-claude-skills.sh;
          bootstrap-mise-test = scriptTest "bootstrap-mise" ./scripts/bootstrap-mise.sh;
          # setup.sh の手順の並び (bootstrap-claude-skills の後) も見るので、scripts/ を丸ごと渡す
          bootstrap-herdr-hub-test = scriptTest "bootstrap-herdr-hub" ./scripts;
          # setup.sh の手順の並び (bootstrap-claude-skills・bootstrap-herdr-hub の後) も見るので、scripts/ を丸ごと渡す
          bootstrap-dev-tracker-inbox-test = scriptTest "bootstrap-dev-tracker-inbox" ./scripts;
          bootstrap-ssh-config-test = scriptTest "bootstrap-ssh-config" ./scripts/bootstrap-ssh-config.sh;
          bootstrap-windows-ssh-config-test = scriptTest "bootstrap-windows-ssh-config" ./scripts/bootstrap-windows-ssh-config.sh;
          bootstrap-windows-powertoys-test = scriptTest "bootstrap-windows-powertoys" ./scripts/bootstrap-windows-powertoys.sh;
          bootstrap-windows-google-ime-install-test = scriptTest "bootstrap-windows-google-ime-install" ./scripts/bootstrap-windows-google-ime-install.sh;
          bootstrap-windows-files-test = scriptTest "bootstrap-windows-files" ./scripts/bootstrap-windows-files.sh;
          bootstrap-windows-terminal-test = scriptTest "bootstrap-windows-terminal" ./scripts/bootstrap-windows-terminal.sh;
          # repo の dotfiles.txt も渡し、警告なしに欄へ入ることを確かめる
          bootstrap-local-env-test = pkgs.runCommand "bootstrap-local-env-test" { } ''
            bash ${./tests/bootstrap-local-env.test.sh} ${./scripts/bootstrap-local-env.sh} ${./pjp-env/dotfiles.txt}
            touch $out
          '';
          # 主に包む前の script を流す。runtimeInputs の fzf が PATH の先頭に来ると、テストが置く
          # 書き留め役の fzf が隠れるため。包んだ後の package は fzf を使わない --list だけを見る
          pjp-pr-diff-test =
            pkgs.runCommand "pjp-pr-diff-test"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.git
                  pkgs.fzf
                ];
              }
              ''
                bash ${./tests/pjp-pr-diff.test.sh} ${./pkgs/pjp-pr-diff/pjp-pr-diff.sh} \
                  ${lib.getExe (pkgs.callPackage ./pkgs/pjp-pr-diff { })}
                touch $out
              '';
          # 包んだ後の package を渡す (-c で付ける組は、Nix が lib/git-via-gh.nix から書き込む)
          git-gh-test = scriptTest "git-gh" (lib.getExe (pkgs.callPackage ./pkgs/git-gh { }));
          # 包む前の script を、偽の ssh-add と python3 で bind した本物の unix socket で流す。flock は script が
          # PATH から使う (Linux の system と同じ util-linux のもの)。starship.toml の警告も本物の starship で読ませる
          pjp-agent-link-test =
            pkgs.runCommand "pjp-agent-link-test"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  pkgs.util-linux
                  pkgs.starship
                ];
              }
              ''
                bash ${./tests/pjp-agent-link.test.sh} ${./pkgs/pjp-agent-link} ${./files/starship.toml}
                touch $out
              '';
        }
        // {
          claude-env-state = import ./tests/claude-env.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          git-gh-aliases-state = import ./tests/git-gh-aliases.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          claude-herdr-skill = import ./tests/claude-herdr-skill.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          claude-notion-state = import ./tests/claude-notion.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          claude-video-offer-state = import ./tests/claude-video-offer.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          claude-ssh-agent-notice-state = import ./tests/claude-ssh-agent-notice.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          claude-xref-guard-state = import ./tests/claude-xref-guard.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          claude-docs-guard-state = import ./tests/claude-docs-guard.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          cc-pages-state = import ./tests/cc-pages.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          mise-release-age-state = import ./tests/mise-release-age.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          dev-tracker-inbox-state = import ./tests/dev-tracker-inbox.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          one-password-state = import ./tests/one-password.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          private-hosts-state = import ./tests/private-hosts.nix { inherit lib pkgs privateHosts; };
          local-flake-tmp-state = import ./tests/local-flake-tmp.nix { inherit lib pkgs mkHome; };
          hosts-with-state = import ./tests/hosts-with.nix {
            inherit
              lib
              pkgs
              system
              hostsWith
              ;
            inherit (self) homeConfigurations;
          };
          host-draft-state = import ./tests/host-draft.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          agent-link-state = import ./tests/agent-link.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          herdr-hyperlink-state = import ./tests/herdr-hyperlink.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          os-ca-bundle-state = import ./tests/os-ca-bundle.nix {
            inherit
              lib
              pkgs
              mkHome
              system
              ;
          };
          release-age-state = import ./tests/release-age.nix {
            inherit
              lib
              pkgs
              system
              inputs
              mkHome
              releaseAge
              ;
          };
        }
      );

      # 初回ブートストラップ用。
      #
      # programs.home-manager.enable が CLI を profile へ入れるのは
      # **初回の activate が成功した後**なので、1 回目は home-manager コマンドが
      # まだ存在しない。そこで flake から直接実行できるようにしておく:
      #
      #   nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#<ホスト>
      #
      # `nix run home-manager` (レジストリ経由) ではなくこちらを使うこと。
      # レジストリ版は nixpkgs 同梱の別バージョンで、flake.lock で固定した
      # home-manager モジュールとバージョンがずれる可能性がある。
      # NOTE: rec の中では属性名 home-manager が input を影にするため、
      #       input 側は inputs. 経由で参照する。
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          home-manager = inputs.home-manager.packages.${system}.default;
          default = home-manager;

          # 閉包を SBOM 化して脆弱性データベース (OSV / GHSA / NVD) と照合する
          # 道具 (ADR 006)。flake-lock-age と同じく他のリポジトリからも呼べる:
          #
          #   nix run 'github:pollenjp/dotfiles?dir=nix#closure-scan' -- report
          #
          # sbomnix は焼き込まない。スキャナの版は「対象 flake の pin された
          # nixpkgs」から取る決めなので、script 側の nix shell --inputs-from に
          # 任せる (焼き込むと dotfiles の pin が他リポジトリにも効いてしまう)。
          closure-scan = pkgs.writeShellApplication {
            name = "closure-scan";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.gawk
            ];
            text = builtins.readFile ./scripts/closure-scan.sh;
          };

          # flake.lock の pin を「公開から N 日以上経った revision」に限る道具。
          # 他のリポジトリからも呼べるように出している (dotfiles 専用ではない):
          #
          #   nix run 'github:pollenjp/dotfiles?dir=nix#flake-lock-age' -- check
          #
          # nix 自身は runtimeInputs に入れない。呼び出し側の nix
          # (Determinate 版など) をそのまま使わせる。
          flake-lock-age = pkgs.writeShellApplication {
            name = "flake-lock-age";
            # closure-scan を PATH へ入れるのは、store の app として update を
            # 叩いたときも完了時のスキャンを差し込めるようにするため
            # (チェックアウトから叩いたときは隣の closure-scan.sh を使う)。
            runtimeInputs = [
              pkgs.coreutils
              pkgs.curl
              pkgs.gnused
              pkgs.gnugrep
              closure-scan
            ];
            text = builtins.readFile ./scripts/flake-lock-age.sh;
          };

          # PR 全体の差分から変更ファイルを fzf で選び、選んだファイルだけの git diff を出す。
          # home には modules/packages.nix が入れる。switch せずに試すなら、見たい PR の branch の
          # checkout の中で:
          #
          #   nix run ~/ghq/github.com/pollenjp/dotfiles/nix#pjp-pr-diff
          pjp-pr-diff = pkgs.callPackage ./pkgs/pjp-pr-diff { };

          # GitHub との通信だけを gh の資格情報 (HTTPS) に向けて git を呼ぶ (git gh <コマンド>)。
          # home には modules/packages.nix が入れる。checks の git-gh-test もこれを流す。
          git-gh = pkgs.callPackage ./pkgs/git-gh { };
        }
        # WSL の .exe の起動を記録する道具 (ADR 012)。bcc も WSL も Linux にしか無い。
        # home には home/modules/exe-exec-trace.nix が入れる。単体で試すなら:
        #
        #   sudo "$(nix build --no-link --print-out-paths ./nix#pjp-exe-exec-trace)/bin/pjp-exe-exec-trace"
        #   nix run ./nix#pjp-who-is-asking
        #
        # Google 日本語入力の設定とテキストを行き来させる道具 (ADR 015) も、WSL のマシンでしか使わない。
        # home には home/modules/windows-files.nix が入れる。CI の lint は nix shell ./nix#pjp-google-ime で借りる。
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          pjp-exe-exec-trace = pkgs.callPackage ./pkgs/pjp-exe-exec-trace { };
          pjp-who-is-asking = pkgs.callPackage ./pkgs/pjp-who-is-asking { };
          pjp-google-ime = pkgs.callPackage ./pkgs/pjp-google-ime { };
        }
      );

      # `nix run <flake>#<名前>` の入口。
      apps = forAllSystems (system: {
        flake-lock-age = {
          type = "app";
          program = "${self.packages.${system}.flake-lock-age}/bin/flake-lock-age";
          meta.description = "flake.lock の pin に最小経過日数を課す";
        };
        closure-scan = {
          type = "app";
          program = "${self.packages.${system}.closure-scan}/bin/closure-scan";
          meta.description = "閉包を SBOM 化して OSV / GHSA / NVD と照合する";
        };
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.shfmt
              pkgs.shellcheck
              pkgs.nixfmt
              # check-test-grep-q.sh が shfmt の構文木を jq で読む
              pkgs.jq
              # check-claude-frontmatter.sh が skill などの frontmatter を YAML として読む
              pkgs.yq-go
              home-manager.packages.${system}.default
            ];
          };
        }
      );
    };
}
