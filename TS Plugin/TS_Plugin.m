classdef TS_Plugin < audioPlugin

    properties
        TONE = 0;
        DRIVE = 0;
        VOLUME = 0;
        ADAA = 'off';
    end

    properties (Constant)
        PluginInterface = audioPluginInterface(...
            'PluginName', 'ScreamerTube',...
            'VendorName', 'JXS',...
            'VendorVersion', '1.0.0',...
            'UniqueId', 'DATt',...
            'BackgroundColor', 'white', ...
            'InputChannels', 2,...
            'OutputChannels', 2,...
            audioPluginGridLayout(...
                'RowHeight', [50 150 50 150 50],...
                'ColumnWidth', [20 150 10 150 10 150 20]...
            ),...
            audioPluginParameter('TONE',...
                'DisplayName', 'Tone',...
                'Style', 'rotaryknob',...
                'Mapping',{'lin',0,100},...
                'Layout', [4,4],...
                'DisplayNameLocation', 'above',...
                'Filmstrip', 'knob.png',...
                'FilmstripFrameSize', [128 128]...
            ),...
            audioPluginParameter('DRIVE',...
                'DisplayName', 'Drive',...
                'Style', 'rotaryknob',...
                'Mapping',{'lin',0,100},...
                'Layout', [2,2],...
                'DisplayNameLocation', 'above',...
                'Filmstrip', 'knob.png',...
                'FilmstripFrameSize', [128 128]...
            ),...
            audioPluginParameter('VOLUME',...
                'DisplayName', 'Level',...
                'Style', 'rotaryknob',...
                'Mapping',{'lin',0,100},...
                'Layout', [2,6],...
                'DisplayNameLocation', 'above',...
                'Filmstrip', 'knob.png',...
                'FilmstripFrameSize', [128 128]...
            ),...
            audioPluginParameter('ADAA',...
                'DisplayName', 'Anti-Aliasing',...
                'Style', 'vrocker',...
                'Mapping', {'enum', 'off', 'on'},...
                'Layout', [4,6],...
                'DisplayNameLocation', 'above',...
                'Filmstrip', 'switch_toggle.png',...
                'FilmstripFrameSize', [56 56]...
            ) ...
        );
    end

    properties (Access = private)
        FS = 44100;

        b_1; a_1;
        b_dhp; a_dhp;
        b_dlp; a_dlp;
        b_2; a_2;
        b_3; a_3;

        z_1; z_dhp; z_dlp; z_2; z_3;

        x_prev_nl;
        rms_gain;
    end

    methods
        function plugin = TS_Plugin()
            updateFixedFilters(plugin);
            updateTone(plugin);
            initStates(plugin);
        end

        function out = process(plugin, in)
            
            ch = size(in, 2);

            if isempty(plugin.z_1) || size(plugin.z_1,2) ~= ch
                initStates(plugin);
            end

            if isempty(plugin.b_1)
                updateFixedFilters(plugin);
            end

            if isempty(plugin.b_2)
                updateTone(plugin);
            end

            x = in;

            [x_hp, plugin.z_1] = filter(plugin.b_1, plugin.a_1, x, plugin.z_1);
            [x_drivehp, plugin.z_dhp] = filter(plugin.b_dhp, plugin.a_dhp, x_hp, plugin.z_dhp);

            drive_alpha = plugin.DRIVE / 100;
            gain = 1 + 9 * (drive_alpha ^ 2);
            x_gain = gain .* x_drivehp;

            Vt = 0.3;

            if strcmpi(plugin.ADAA, 'on')
                x_nl = adaa_nl(plugin, x_gain, Vt);
            else
                x_nl = Vt * tanh(x_gain / Vt);
            end

            x_clip = (1 - drive_alpha) * x_hp + drive_alpha * x_nl;

            [x_drivetotal, plugin.z_dlp] = filter(plugin.b_dlp, plugin.a_dlp, x_clip, plugin.z_dlp);
            [x_tone, plugin.z_2] = filter(plugin.b_2, plugin.a_2, x_drivetotal, plugin.z_2);

            rms_in = sqrt(mean(x_drivetotal .^ 2, 1));
            rms_out = sqrt(mean(x_tone .^ 2, 1));

            gain_match = ones(1, ch);
            idx = rms_out > 0;
            gain_match(idx) = rms_in(idx) ./ rms_out(idx);
            gain_match = min(gain_match, 3);

            alpha = 0.999;
            if isempty(plugin.rms_gain) || numel(plugin.rms_gain) ~= ch
                plugin.rms_gain = gain_match;
            else
                plugin.rms_gain = alpha * plugin.rms_gain + (1 - alpha) * gain_match;
            end

            x_tone = x_tone .* plugin.rms_gain;

            volume_alpha = plugin.VOLUME / 100;
            x_volume = volume_alpha * x_tone;

            [out, plugin.z_3] = filter(plugin.b_3, plugin.a_3, x_volume, plugin.z_3);
        end

        function reset(plugin)
            plugin.FS = getSampleRate(plugin);
            updateFixedFilters(plugin);
            updateTone(plugin);
            initStates(plugin);
        end

        function set.TONE(plugin, val)
            plugin.TONE = min(max(val, 0), 100);
            updateTone(plugin);
        end

        function set.DRIVE(plugin, val)
            plugin.DRIVE = min(max(val, 0), 100);
        end

        function set.VOLUME(plugin, val)
            plugin.VOLUME = min(max(val, 0), 100);
        end

        function set.ADAA(plugin, val)
            plugin.ADAA = val;
        end
    end

    methods (Access = private)

        function initStates(plugin)
            ch = 2;

            n_1 = max(length(plugin.a_1), length(plugin.b_1)) - 1;
            n_dhp = max(length(plugin.a_dhp), length(plugin.b_dhp)) - 1;
            n_dlp = max(length(plugin.a_dlp), length(plugin.b_dlp)) - 1;
            n_2 = max(length(plugin.a_2), length(plugin.b_2)) - 1;
            n_3 = max(length(plugin.a_3), length(plugin.b_3)) - 1;

            plugin.z_1 = zeros(n_1, ch);
            plugin.z_dhp = zeros(n_dhp, ch);
            plugin.z_dlp = zeros(n_dlp, ch);
            plugin.z_2 = zeros(n_2, ch);
            plugin.z_3 = zeros(n_3, ch);

            plugin.x_prev_nl = zeros(1, ch);
            plugin.rms_gain = ones(1, ch);
        end

        function updateFixedFilters(plugin)
            Fs = plugin.FS;

            R = 338000; C = 2e-8; Av = 0.993;
            [plugin.b_1, plugin.a_1] = bilinear([Av*R*C 0], [R*C 1], Fs);

            R4 = 4.7e3; C3 = 0.047e-6;
            [plugin.b_dhp, plugin.a_dhp] = bilinear([R4*C3 0], [R4*C3 1], Fs);

            R6 = 51e3; C4 = 51e-12;
            [plugin.b_dlp, plugin.a_dlp] = bilinear([1], [R6*C4 1], Fs);

            R = 10000; C = 10e-6;
            [plugin.b_3, plugin.a_3] = bilinear([C*R 0], [C*R 1], Fs);
        end

        function updateTone(plugin)
            Fs = plugin.FS;
            T = plugin.TONE / 100;

            Cz = 0.1e-6; Rz = 220; Rf = 1000;
            Rload = 10000; Rpot = 20000;

            Rl = max(T * Rpot, 1);

            wp1 = 1 / (Cz * (Rz + Rf));
            wp2 = 1 / (Cz * Rload);
            wz = 1 / (Cz * (Rz + Rl));

            K = (Rload + Rf) / Rload;

            num = K * [1, wz];
            den = conv([1, wp1], [1, wp2]);

            [plugin.b_2, plugin.a_2] = bilinear(num, den, Fs);

            H = freqz(plugin.b_2, plugin.a_2, 1024);
            peakGain = max(abs(H));

            if peakGain > 0
                plugin.b_2 = plugin.b_2 / peakGain;
            end
        end

        function y = adaa_nl(plugin, x, Vt)
            [N, ch] = size(x);
            y = zeros(N, ch);
            x_prev = plugin.x_prev_nl;

            for n = 1:N
                x_n = x(n, :);
                dx = x_n - x_prev;

                F_x = (Vt^2) * logcosh_stable(plugin, x_n / Vt);
                F_prev = (Vt^2) * logcosh_stable(plugin, x_prev / Vt);

                y_n = zeros(1, ch);
                small = abs(dx) < 1e-12;

                y_n(small) = Vt * tanh(x_n(small) / Vt);
                y_n(~small) = (F_x(~small) - F_prev(~small)) ./ dx(~small);

                y(n, :) = y_n;
                x_prev = x_n;
            end

            plugin.x_prev_nl = x_prev;
        end

        function y = logcosh_stable(~, x)
            ax = abs(x);
            y = ax + log1p(exp(-2 * ax)) - log(2);
        end

    end
    
end

