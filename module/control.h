/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright(c) 2021-2022 Intel Corporation
 *
 * Authors: Amadeusz Slawinski <amadeuszx.slawinski@linux.intel.com>
 *          Cezary Rojewski <cezary.rojewski@intel.com>
 */

#ifndef __SOUND_SOC_INTEL_AVS_CTRL_H
#define __SOUND_SOC_INTEL_AVS_CTRL_H

#include <linux/list.h>
#include <sound/control.h>
#include <uapi/sound/asoc.h>

struct avs_dev;
struct avs_path_module;

struct avs_control_data {
	u32 id;
	long values[SND_SOC_TPLG_MAX_CHAN];
	/* TLV bytes controls: cached payload + topology-wide list. */
	struct avs_dev *adev;
	struct list_head node;
	void *tlv_data;
};

int avs_control_volume_get(struct snd_kcontrol *kctl, struct snd_ctl_elem_value *uctl);
int avs_control_volume_put(struct snd_kcontrol *kctl, struct snd_ctl_elem_value *uctl);
int avs_control_volume_info(struct snd_kcontrol *kctl, struct snd_ctl_elem_info *uinfo);
int avs_control_mute_get(struct snd_kcontrol *kctl, struct snd_ctl_elem_value *uctl);
int avs_control_mute_put(struct snd_kcontrol *kctl, struct snd_ctl_elem_value *uctl);
int avs_control_mute_info(struct snd_kcontrol *kctl, struct snd_ctl_elem_info *uinfo);

int avs_tlv_control_set(struct snd_kcontrol *kctl, const unsigned int __user *data,
			unsigned int size);
int avs_kcontrol_tlv_module_init(struct avs_dev *adev, struct avs_path_module *mod);

#endif
